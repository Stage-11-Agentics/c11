import Foundation

/// Which viewer belongs to which (caller, source), and which ones the
/// operator closed (C11H-228). Pure bookkeeping; the controller owns the
/// panels. Rules from the design:
/// - (caller, source) is the dedupe key: a re-show refreshes the same viewer.
/// - A viewer the operator closed stays closed until the agent shows again;
///   nothing else (a save, a poll, a drain) reopens it.
/// - At most `ShowSpec.maxViewersPerCaller` live viewers per caller; a new
///   one past the cap replaces that caller's oldest.
struct ShowRegistry: Equatable {
    struct Viewer: Equatable {
        var panel: UUID
        var caller: UUID
        var sourceKey: String
        var openedAt: Date
    }

    enum Decision: Equatable {
        /// The same viewer is still open: refresh it.
        case refresh(panel: UUID)
        /// Open a new viewer. `replacing` is the caller's oldest viewer to
        /// close first (cap reached); `reopening` says the operator had closed
        /// a viewer for this source and the agent showed it again.
        case open(replacing: UUID?, reopening: Bool)
    }

    private(set) var live: [String: Viewer] = [:]
    private(set) var operatorClosed: Set<String> = []
    let cap: Int

    init(cap: Int = ShowSpec.maxViewersPerCaller) { self.cap = cap }

    static func key(caller: UUID, sourceKey: String) -> String {
        caller.uuidString.lowercased() + "\u{1E}" + sourceKey
    }

    func viewers(of caller: UUID) -> [Viewer] {
        live.values.filter { $0.caller == caller }.sorted { $0.openedAt < $1.openedAt }
    }

    func viewer(panel: UUID) -> Viewer? { live.values.first { $0.panel == panel } }

    func viewer(caller: UUID, sourceKey: String) -> Viewer? { live[Self.key(caller: caller, sourceKey: sourceKey)] }

    func isOperatorClosed(caller: UUID, sourceKey: String) -> Bool {
        operatorClosed.contains(Self.key(caller: caller, sourceKey: sourceKey))
    }

    /// What an explicit show from `caller` of `sourceKey` should do.
    func decide(caller: UUID, sourceKey: String) -> Decision {
        let key = Self.key(caller: caller, sourceKey: sourceKey)
        if let viewer = live[key] { return .refresh(panel: viewer.panel) }
        let mine = viewers(of: caller)
        let replacing = mine.count >= cap ? mine.first?.panel : nil
        return .open(replacing: replacing, reopening: operatorClosed.contains(key))
    }

    mutating func opened(panel: UUID, caller: UUID, sourceKey: String, at: Date) {
        let key = Self.key(caller: caller, sourceKey: sourceKey)
        live[key] = Viewer(panel: panel, caller: caller, sourceKey: sourceKey, openedAt: at)
        operatorClosed.remove(key)
    }

    /// A viewer panel went away. `byOperator` marks it closed until the
    /// agent shows that source again. Returns the viewer it was, if any.
    @discardableResult
    mutating func closed(panel: UUID, byOperator: Bool) -> Viewer? {
        guard let (key, viewer) = live.first(where: { $0.value.panel == panel }) else { return nil }
        live.removeValue(forKey: key)
        if byOperator { operatorClosed.insert(key) }
        return viewer
    }

    /// Whether a refresh (live reload) may touch `panel`: only a live viewer.
    func mayRefresh(panel: UUID) -> Bool { viewer(panel: panel) != nil }
}

/// The live-reload rule, without a clock or a machine. While the viewer is
/// visible, ask for the file's size and mtime each tick; load when they
/// differ from what the viewer last loaded, when nothing was loaded yet (a
/// restored viewer), or after a failed load. A stat counts as loaded only
/// once its bytes loaded; one load at a time; hidden, ask nothing.
struct ShowReloadRule: Equatable {
    enum Step: Equatable { case idle, stat }
    enum Outcome: Equatable { case unchanged, changed }

    /// The stat of the bytes the viewer shows now.
    private(set) var last: ShowFileStat?
    /// The last load failed: the next answered stat loads again.
    private(set) var stale = false
    /// A load is in flight for this stat.
    private(set) var pending: ShowFileStat?

    init(last: ShowFileStat? = nil) { self.last = last }

    func step(visible: Bool) -> Step { visible && pending == nil ? .stat : .idle }

    mutating func markStale() { stale = true }

    /// Records a stat answer; `.changed` means load it (and it is now pending).
    mutating func observe(_ stat: ShowFileStat) -> Outcome {
        guard pending == nil else { return .unchanged }
        guard stale || last == nil || last != stat else { return .unchanged }
        pending = stat
        return .changed
    }

    /// The pending load succeeded: its stat is what the viewer shows.
    mutating func loaded(_ stat: ShowFileStat?) {
        if let stat { last = stat }
        pending = nil
        stale = false
    }

    /// The pending load failed: try again on the next answered stat.
    mutating func failed() {
        pending = nil
        stale = true
    }
}

/// What a viewer's first load (or a refresh) told the caller.
struct ShowLoadResult: Equatable, Sendable {
    enum Status: String, Sendable { case loaded, failed, blank, timeout }

    var status: Status
    var reason: String?
    var httpStatus: Int?
    var scriptErrors: Int = 0
    var refusedAssets: Int = 0
    var textLength: Int?
    var elements: Int?

    var dictionary: [String: Any] {
        var value: [String: Any] = ["status": status.rawValue, "script_errors": scriptErrors, "refused_assets": refusedAssets]
        if let reason { value["reason"] = reason }
        if let httpStatus { value["http_status"] = httpStatus }
        if let textLength { value["text_length"] = textLength }
        if let elements { value["elements"] = elements }
        return value
    }
}

/// Turns what the page and the scheme handler said into a load result.
enum ShowLoadJudge {
    /// Whether a finished main-frame load answers a show: any page but the
    /// initial `about:` document, so a redirect's final page counts.
    static func countsAsLoad(_ finished: String?) -> Bool {
        guard let finished, let scheme = URLComponents(string: finished)?.scheme?.lowercased() else { return false }
        return scheme != "about"
    }

    /// Whether the viewer is on the shown page itself (fragment aside), so a
    /// re-show reloads it in place rather than going back to the source.
    static func isShownPage(_ finished: String?, address: URL) -> Bool {
        guard let finished, var got = URLComponents(string: finished),
              var want = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return false }
        got.fragment = nil
        want.fragment = nil
        if got.path.isEmpty { got.path = "/" }
        if want.path.isEmpty { want.path = "/" }
        return ShowSpec.canonicalScheme(got.scheme) == ShowSpec.canonicalScheme(want.scheme)
            && got.host?.lowercased() == want.host?.lowercased()
            && got.port == want.port && got.path == want.path && got.percentEncodedQuery == want.percentEncodedQuery
    }

    /// The DOM facts the check reads after the page finished loading.
    struct Page: Equatable, Sendable {
        var textLength: Int
        var elements: Int
        /// Images, canvases, video, svg and iframes: a page of only these is not blank.
        var media: Int
        var scriptErrors: Int
    }

    static func httpReason(_ status: Int) -> String {
        "HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))"
    }

    /// A navigation failure, or an entry the handler could not serve, fails.
    /// A finished page with no text, no media and almost no elements is blank.
    static func judge(failure: String?, entryStatus: Int?, page: Page?, refusedAssets: Int) -> ShowLoadResult {
        if let failure {
            return ShowLoadResult(status: .failed, reason: failure, httpStatus: entryStatus, refusedAssets: refusedAssets)
        }
        if let entryStatus, !(200..<300).contains(entryStatus) {
            return ShowLoadResult(status: .failed, reason: httpReason(entryStatus), httpStatus: entryStatus,
                                  scriptErrors: page?.scriptErrors ?? 0, refusedAssets: refusedAssets)
        }
        guard let page else {
            return ShowLoadResult(status: .loaded, httpStatus: entryStatus, refusedAssets: refusedAssets)
        }
        let blank = page.textLength == 0 && page.media == 0 && page.elements <= 2
        return ShowLoadResult(status: blank ? .blank : .loaded, httpStatus: entryStatus, scriptErrors: page.scriptErrors,
                              refusedAssets: refusedAssets, textLength: page.textLength, elements: page.elements)
    }

    /// The script the check runs (in its own content world, reading only).
    static let pageScript = """
    (() => {
      const b = document.body;
      const log = window.__cmuxErrorLog;
      return {
        text: b ? (b.innerText || '').trim().length : 0,
        elements: b ? b.querySelectorAll('*').length : 0,
        media: b ? b.querySelectorAll('img,canvas,video,svg,iframe,object,embed').length : 0,
        errors: 0
      };
    })()
    """

    /// The error log lives in the page's own world (the browser's telemetry hook).
    static let errorCountScript = "Array.isArray(window.__cmuxErrorLog) ? window.__cmuxErrorLog.length : 0"

    static func page(from value: Any?, errors: Any?) -> Page? {
        guard let object = value as? [String: Any] else { return nil }
        func int(_ any: Any?) -> Int { (any as? NSNumber)?.intValue ?? 0 }
        return Page(textLength: int(object["text"]), elements: int(object["elements"]), media: int(object["media"]),
                    scriptErrors: int(errors))
    }
}

/// A main-frame navigation fact a viewer's load check listens for.
enum ShowNavigationEvent: Equatable, Sendable {
    case response(status: Int)
    /// The main frame finished loading `url`.
    case finished(url: String?)
    case failed(String)
    /// C11H-247: the main frame committed a document. `freshLoad` is false
    /// for a back/forward restore, which may bring back a cached page whose
    /// frames never navigate again.
    case committed(url: String?, freshLoad: Bool)
    /// C11H-247: WebKit reported a frame other than the main frame (a
    /// subframe navigation or response, or c11's own probe in one).
    case subframe
}
