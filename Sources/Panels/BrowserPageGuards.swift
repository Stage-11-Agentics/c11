import AppKit
import Bonsplit
import WebKit

// C11H-377: what a page may do on its own. A page reaches the operator's
// screen and keys only with the operator's activation: a real key or mouse
// event AppKit delivered to that page's web view. A page's own `click()` or
// `dispatchEvent` never reaches AppKit, so it never counts. Every decision
// here is pure; the WebKit delegates of a browser panel and of its popups
// call the same functions.

/// When the operator last touched a page, and how recent counts.
enum BrowserActivation {
    /// A scripted popup needs operator input this recent (the transient
    /// activation window Chrome and Firefox use).
    static let popupWindow: TimeInterval = 5
    /// A JS dialog is shown at once only with input this recent, or while
    /// the page holds the operator's focus.
    static let dialogWindow: TimeInterval = 5
    /// A download needs activation this recent when its response arrives;
    /// longer than the popup window, since a server can be slow to answer.
    static let downloadWindow: TimeInterval = 10

    static func isRecent(_ at: Date?, now: Date, within window: TimeInterval) -> Bool {
        guard let at else { return false }
        let age = now.timeIntervalSince(at)
        return age >= 0 && age < window
    }

    static func latest(_ dates: Date?...) -> Date? { dates.compactMap { $0 }.max() }
}

// MARK: - Downloads (N7)

enum BrowserDownloadDecision: Equatable {
    case allow
    /// A show viewer never downloads.
    case refuseViewer
    /// No operator input (or local browser command) preceded it.
    case refuseNoActivation
}

enum BrowserDownloadPolicy {
    /// `lastActivation` is the latest of the operator's input on the page, an
    /// address-bar submit, and a local `browser.*` socket command on the panel.
    static func decide(isShowViewer: Bool, lastActivation: Date?, now: Date = Date()) -> BrowserDownloadDecision {
        if isShowViewer { return .refuseViewer }
        guard BrowserActivation.isRecent(lastActivation, now: now, within: BrowserActivation.downloadWindow) else {
            return .refuseNoActivation
        }
        return .allow
    }

    static func notice(for decision: BrowserDownloadDecision, host: String?) -> String? {
        switch decision {
        case .allow: return nil
        case .refuseViewer:
            return String(localized: "browser.download.blocked.viewer", defaultValue: "Downloads are off in a shown page.")
        case .refuseNoActivation:
            let who = host ?? String(localized: "browser.externalOpen.thisPage", defaultValue: "This page")
            return String(format: String(localized: "browser.download.blocked.noGesture",
                                         defaultValue: "Blocked a download from %@ that did not follow a click on this page."), who)
        }
    }
}

/// The downloads a delegate has in flight, so closing their panel stops them
/// and removes what they wrote. Generic over the download handle so tests
/// need no WebKit download.
final class BrowserActiveDownloads<Handle: AnyObject> {
    struct Entry {
        let handle: Handle
        let tempURL: URL
        let suggestedFilename: String
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private let lock = NSLock()
    private(set) var closed = false

    /// False once the owner has closed; the caller then cancels the download.
    @discardableResult
    func add(_ entry: Entry) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        entries[ObjectIdentifier(entry.handle)] = entry
        return true
    }

    func remove(_ handle: Handle) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.removeValue(forKey: ObjectIdentifier(handle))
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// Cancels every download through `cancel`, deletes their temp files, and
    /// refuses any later `add`. Returns the files it removed.
    @discardableResult
    func cancelAll(fileManager: FileManager = .default, cancel: (Handle) -> Void) -> [URL] {
        lock.lock()
        closed = true
        let all = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        for entry in all {
            cancel(entry.handle)
            try? fileManager.removeItem(at: entry.tempURL)
        }
        return all.map(\.tempURL)
    }
}

// MARK: - Popups (N8)

enum BrowserPopupPolicy {
    /// Whether a scripted `window.open` may open a window: only right after
    /// the operator's own input on that page, and only while it is on screen.
    /// A sign-in button the operator clicks passes; a timer or a hidden page
    /// does not.
    static func allows(lastOperatorInput: Date?, onScreen: Bool, now: Date = Date()) -> Bool {
        onScreen && BrowserActivation.isRecent(lastOperatorInput, now: now, within: BrowserActivation.popupWindow)
    }

    static func notice(host: String?) -> String {
        let who = host ?? String(localized: "browser.externalOpen.thisPage", defaultValue: "This page")
        return String(format: String(localized: "browser.popup.blocked", defaultValue: "Blocked a pop-up window from %@."), who)
    }
}

// MARK: - JS dialogs (N8)

enum BrowserJSDialogDecision: Equatable {
    case present
    /// Held until the operator clicks or types in that page.
    case queue
    case safeDefault(Reason)

    enum Reason: String, Equatable {
        case showViewer = "show_viewer"
        case rateLimited = "rate_limited"
        case alreadyQueued = "already_queued"
    }
}

/// At most `limit` dialogs shown per `window` seconds for one panel and its
/// popups; past that a dialog resolves with its safe default.
struct BrowserJSDialogRateLimiter: Equatable {
    var limit = 3
    var window: TimeInterval = 10
    private(set) var shown: [Date] = []

    func admits(now: Date) -> Bool {
        shown.filter { now.timeIntervalSince($0) < window }.count < limit
    }

    mutating func record(now: Date) {
        shown = shown.filter { now.timeIntervalSince($0) < window } + [now]
    }
}

enum BrowserJSDialogPolicy {
    /// - A show viewer never shows one.
    /// - Otherwise a dialog shows now only when its page is on screen and the
    ///   operator is with it (the page holds focus in the key window, or the
    ///   operator touched it in the last few seconds); else it waits.
    /// - Everywhere, the rate limit decides last.
    static func decide(
        isShowViewer: Bool,
        onScreen: Bool,
        operatorFocused: Bool,
        lastOperatorInput: Date?,
        limiter: BrowserJSDialogRateLimiter,
        now: Date = Date()
    ) -> BrowserJSDialogDecision {
        if isShowViewer { return .safeDefault(.showViewer) }
        let withOperator = operatorFocused
            || BrowserActivation.isRecent(lastOperatorInput, now: now, within: BrowserActivation.dialogWindow)
        guard onScreen, withOperator else { return .queue }
        return limiter.admits(now: now) ? .present : .safeDefault(.rateLimited)
    }
}

/// The page is in its window and on screen: a keep-live panel parked for a
/// hidden workspace is unhidden but moved off its host, so only a page that
/// actually overlaps its window's content counts.
@MainActor
func browserWebViewIsOnScreen(_ webView: NSView, minimumSide: CGFloat = 40) -> Bool {
    guard let window = webView.window, let content = window.contentView,
          window.isVisible, !webView.isHiddenOrHasHiddenAncestor else { return false }
    let shown = webView.convert(webView.bounds, to: nil).intersection(content.convert(content.bounds, to: nil))
    return shown.width >= minimumSide && shown.height >= minimumSide
}

/// The page holds keyboard focus in the key window.
@MainActor
func browserWebViewHasOperatorFocus(_ webView: NSView) -> Bool {
    guard let window = webView.window, window.isKeyWindow,
          let responder = window.firstResponder as? NSView else { return false }
    return responder === webView || responder.isDescendant(of: webView)
}

/// One per browser panel, shared with its popups: decides each JS dialog,
/// holds a waiting one, counts shown ones. The caller presents, only through
/// `browserPresentModalAlert` (a sheet, never `runModal`).
@MainActor
final class BrowserJSDialogGate {
    typealias Response = NSApplication.ModalResponse
    /// Shows the dialog and calls back with the operator's answer.
    typealias Present = (@escaping (Response) -> Void) -> Void

    struct Pending {
        let safeDefault: Response
        let present: Present
        let completion: (Response) -> Void
        /// A page whose view is gone (a crashed or replaced web view) frees
        /// its slot, so a new view at the same address is never refused.
        weak var view: NSView?
    }

    let isShowViewer: Bool
    private(set) var limiter = BrowserJSDialogRateLimiter()
    private var waiting: [ObjectIdentifier: Pending] = [:]
    private let notices = PanelLinkNoticePresenter()
    var now: () -> Date = Date.init
    /// Seams for tests; the defaults read the real view.
    var onScreen: @MainActor (NSView) -> Bool = { browserWebViewIsOnScreen($0) }
    var operatorFocused: @MainActor (NSView) -> Bool = { browserWebViewHasOperatorFocus($0) }
    var showNotice: @MainActor (String, NSView) -> Void

    init(isShowViewer: Bool) {
        self.isShowViewer = isShowViewer
        let notices = self.notices
        showNotice = { text, view in notices.show(text: text, in: view) }
    }

    var waitingCount: Int { waiting.count }

    /// A page in `view` asked for a dialog. `completion` runs exactly once.
    func request(
        for view: NSView,
        safeDefault: Response,
        lastOperatorInput: Date?,
        present: @escaping Present,
        completion: @escaping (Response) -> Void
    ) {
        let key = ObjectIdentifier(view)
        pruneGoneViews()
        if waiting[key] != nil {
            Self.log(.safeDefault(.alreadyQueued))
            completion(safeDefault)
            return
        }
        let decision = BrowserJSDialogPolicy.decide(
            isShowViewer: isShowViewer,
            onScreen: onScreen(view),
            operatorFocused: operatorFocused(view),
            lastOperatorInput: lastOperatorInput,
            limiter: limiter,
            now: now()
        )
        Self.log(decision)
        switch decision {
        case .present:
            limiter.record(now: now())
            present(completion)
        case .queue:
            waiting[key] = Pending(safeDefault: safeDefault, present: present, completion: completion, view: view)
            showNotice(String(localized: "browser.dialog.queued",
                              defaultValue: "This page wants to show a dialog. Click the page to see it."), view)
        case .safeDefault:
            completion(safeDefault)
        }
    }

    /// The operator clicked or typed in `view`: a dialog waiting for it is
    /// decided again, now with that input.
    func operatorDidInteract(with view: NSView, at: Date? = nil) {
        guard let pending = waiting.removeValue(forKey: ObjectIdentifier(view)) else { return }
        request(for: view, safeDefault: pending.safeDefault, lastOperatorInput: at ?? now(),
                present: pending.present, completion: pending.completion)
    }

    private func pruneGoneViews() {
        for (key, pending) in waiting where pending.view == nil {
            waiting.removeValue(forKey: key)
            pending.completion(pending.safeDefault)
        }
    }

    /// A page going away answers its waiting dialog with the safe default.
    func flush(_ view: NSView) {
        guard let pending = waiting.removeValue(forKey: ObjectIdentifier(view)) else { return }
        pending.completion(pending.safeDefault)
    }

    /// The panel is closing: every waiting dialog, its popups' too, answers
    /// its safe default, so no completion outlives the gate.
    func flushAll() {
        let all = waiting.values
        waiting.removeAll()
        all.forEach { $0.completion($0.safeDefault) }
    }

    private static func log(_ decision: BrowserJSDialogDecision) {
#if DEBUG
        switch decision {
        case .present: dlog("browser.dialog decision=present")
        case .queue: dlog("browser.dialog decision=queue")
        case .safeDefault(let reason): dlog("browser.dialog decision=safe_default reason=\(reason.rawValue)")
        }
#endif
    }
}

// MARK: - Focus tracking (N9)

/// c11's address-bar focus restore. Its scripts run in c11's own content
/// world in every frame, where page scripts can neither see them nor reach
/// their handler. Each frame keeps its own last field and caret there; it
/// tells c11 only whether a field holds focus, and only when focus moves.
/// WebKit's `frameInfo` on the message, not the page, names the frame.
enum BrowserFocusTracking {
    static let world = WKContentWorld.world(name: "c11-focus")
    static let handlerName = "c11FocusState"

    @MainActor
    static func install(into sink: BrowserFocusTrackingSink, handler: WKScriptMessageHandler) {
        sink.addHandler(handler, in: world, name: handlerName)
        sink.addScript(bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    /// What one message says: whether the sending frame now holds a focused field.
    static func focused(fromMessageBody body: Any) -> Bool? {
        (body as? [String: Any])?["focused"] as? Bool
    }

    static let bootstrapScript = """
    (() => {
      try {
        if (window.__c11Focus) return true;
        const sink = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
        const t = { target: null, start: null, end: null };
        const isEditable = (el) => {
          if (!el) return false;
          const tag = (el.tagName || "").toLowerCase();
          const type = (el.type || "").toLowerCase();
          return !!el.isContentEditable || tag === "textarea" || (tag === "input" && type !== "hidden");
        };
        const isFrame = (el) => {
          const tag = el ? (el.tagName || "").toLowerCase() : "";
          return tag === "iframe" || tag === "frame";
        };
        const report = (focused) => { try { if (sink) sink.postMessage({ focused: !!focused }); } catch (_) {} };
        const clear = () => { t.target = null; t.start = null; t.end = null; };
        const keepCaret = (el) => {
          if (typeof el.selectionStart === "number" && typeof el.selectionEnd === "number") {
            t.start = el.selectionStart; t.end = el.selectionEnd;
          } else { t.start = null; t.end = null; }
        };
        const take = (el) => {
          if (!isEditable(el)) { clear(); return false; }
          t.target = el; keepCaret(el); return true;
        };
        const caret = () => {
          const el = document.activeElement;
          if (el && el === t.target) keepCaret(el);
        };
        t.capture = () => {
          const el = document.activeElement;
          if (isFrame(el)) return "kept:frame";
          if (take(el)) { report(true); return "captured"; }
          report(false);
          return "cleared";
        };
        t.restore = () => {
          const el = t.target;
          if (!el) return "no_state";
          if (!el.isConnected) { clear(); report(false); return "missing_target"; }
          try { el.focus({ preventScroll: true }); } catch (_) { try { el.focus(); } catch (_) {} }
          let focused = false;
          try { focused = el === el.ownerDocument.activeElement || (typeof el.matches === "function" && el.matches(":focus")); } catch (_) {}
          if (!focused) return "not_focused";
          if (typeof t.start === "number" && typeof t.end === "number" && typeof el.setSelectionRange === "function") {
            try { el.setSelectionRange(t.start, t.end); } catch (_) {}
          }
          clear();
          return "restored";
        };
        window.__c11Focus = t;
        document.addEventListener("focusin", (ev) => { report(take(ev && ev.target ? ev.target : document.activeElement)); }, true);
        document.addEventListener("selectionchange", caret, true);
        document.addEventListener("input", caret, true);
        document.addEventListener("mousedown", (ev) => {
          if (!isEditable(ev && ev.target ? ev.target : null)) { clear(); report(false); }
        }, true);
        window.addEventListener("beforeunload", () => { clear(); report(false); }, true);
        if (take(document.activeElement)) report(true);
        return true;
      } catch (_) {
        return false;
      }
    })();
    """

    static let captureScript = """
    (() => { try { return window.__c11Focus ? window.__c11Focus.capture() : "no_tracker"; } catch (_) { return "error"; } })();
    """

    static let restoreScript = """
    (() => { try { return window.__c11Focus ? window.__c11Focus.restore() : "no_state"; } catch (_) { return "error"; } })();
    """
}

/// Where c11 installs the focus scripts and handler: `WKUserContentController`
/// in the app, a recorder in tests.
@MainActor
protocol BrowserFocusTrackingSink {
    func addScript(_ source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool, in world: WKContentWorld)
    func addHandler(_ handler: WKScriptMessageHandler, in world: WKContentWorld, name: String)
}

extension WKUserContentController: BrowserFocusTrackingSink {
    func addScript(_ source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool, in world: WKContentWorld) {
        addUserScript(WKUserScript(source: source, injectionTime: injectionTime, forMainFrameOnly: forMainFrameOnly, in: world))
    }

    func addHandler(_ handler: WKScriptMessageHandler, in world: WKContentWorld, name: String) {
        add(handler, contentWorld: world, name: name)
    }
}

/// Receives the focus script's messages for one web view and remembers which
/// frame last reported a focused field. The handler is weak to its owner, so
/// the content controller's strong hold never keeps a panel alive.
final class BrowserFocusStateHandler: NSObject, WKScriptMessageHandler {
    /// The frame whose field held focus last, by WebKit's word.
    private(set) var focusedFrame: WKFrameInfo?
    private(set) var hasFocusedField = false
    /// Only this web view's messages count; a popup made from the same
    /// configuration posts to the same handler.
    weak var webView: WKWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world.name == BrowserFocusTracking.world.name else { return }
        if let webView, let from = message.webView, from !== webView { return }
        guard let focused = BrowserFocusTracking.focused(fromMessageBody: message.body) else { return }
        note(focused: focused, frame: message.frameInfo)
    }

    /// Last report wins, as a click anywhere that is not a field clears it.
    func note(focused: Bool, frame: WKFrameInfo?) {
        hasFocusedField = focused
        focusedFrame = focused ? frame : nil
    }

    func forgetFrame() { focusedFrame = nil }
}
