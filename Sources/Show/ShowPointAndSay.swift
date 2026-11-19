import AppKit
import Foundation
import WebKit

/// Point and say (C11H-228): the operator Option-clicks an element in a shown
/// page, types one line, and it arrives as mail to the agent that showed it,
/// with the element's selector and text, a cropped screenshot and the page's
/// hash. The agent never gets control; it gets the operator's words with a
/// pointer.
///
/// Only a real mouse-down the window server delivered to the viewer's web
/// view starts it (`CmuxWebView.mouseDown`), so a page script cannot: there is
/// no script message handler, and the element is read from c11's own content
/// world after the click.
enum ShowPointAndSay {
    static let topic = "show.point"
    static let sender = "operator"

    /// The gate: a left mouse-down with Option (and no Command or Control)
    /// on a viewer panel's web view.
    static func accepts(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, isViewer: Bool) -> Bool {
        guard isViewer, type == .leftMouseDown else { return false }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.option) && !flags.contains(.command) && !flags.contains(.control)
    }

    /// What c11 read about the clicked element.
    struct Element: Equatable {
        var selector: String
        var tag: String
        var text: String
        /// In CSS pixels, relative to the viewport.
        var rect: CGRect
        var hash: String
        var url: String
        var title: String

        init?(_ value: Any?) {
            guard let object = value as? [String: Any], let selector = object["selector"] as? String, !selector.isEmpty else { return nil }
            func number(_ key: String) -> CGFloat { CGFloat((object[key] as? NSNumber)?.doubleValue ?? 0) }
            self.selector = String(selector.prefix(512))
            tag = object["tag"] as? String ?? ""
            text = String((object["text"] as? String ?? "").prefix(280))
            rect = CGRect(x: number("x"), y: number("y"), width: number("w"), height: number("h"))
            hash = String((object["hash"] as? String ?? "").prefix(512))
            url = object["url"] as? String ?? ""
            title = String((object["title"] as? String ?? "").prefix(200))
        }

        init(selector: String, tag: String, text: String, rect: CGRect, hash: String, url: String, title: String) {
            self.selector = selector; self.tag = tag; self.text = text; self.rect = rect
            self.hash = hash; self.url = url; self.title = title
        }
    }

    /// Reads the element under (x, y) in CSS pixels. Runs in c11's own
    /// content world: the page's scripts cannot see or replace it.
    static let elementScript = """
    const el = document.elementFromPoint(x, y);
    if (!el) { return null; }
    const path = (node) => {
      if (node.id) { return '#' + CSS.escape(node.id); }
      const parts = [];
      for (let n = node; n && n.nodeType === 1 && n !== document.documentElement; n = n.parentElement) {
        if (n.id) { parts.unshift('#' + CSS.escape(n.id)); break; }
        let i = 1; for (let s = n.previousElementSibling; s; s = s.previousElementSibling) { if (s.tagName === n.tagName) { i++; } }
        parts.unshift(n.tagName.toLowerCase() + ':nth-of-type(' + i + ')');
      }
      return parts.join(' > ');
    };
    const r = el.getBoundingClientRect();
    return { selector: path(el), tag: el.tagName.toLowerCase(), text: (el.innerText || el.textContent || '').trim().slice(0, 280),
             x: r.x, y: r.y, w: r.width, h: r.height, hash: location.hash, url: location.href, title: document.title };
    """

    /// The second guard, run immediately before a capture: any element that
    /// can hold another document, anywhere in the page (open shadow roots
    /// included). The first guard is WebKit's own frame reports
    /// (`ShowViewerSession.hasEmbeddedContent`), which also see frames in
    /// closed shadow roots.
    static let embeddedContentScript = """
    const visit = (root) => {
      if (root.querySelector('iframe, frame, embed, object')) { return true; }
      for (const node of root.querySelectorAll('*')) { if (node.shadowRoot && visit(node.shadowRoot)) { return true; } }
      return false;
    };
    return visit(document);
    """

    /// Where the clicked page sits relative to what was shown (C11H-247).
    enum PageScope: Equatable {
        /// The shown page itself (fragment aside).
        case shown
        /// Another page of the same source: the same `c11-show` machine, or
        /// the same origin as a shown URL. Still the agent's own content.
        case sameSource
        /// Anywhere else (a search engine, a site a link led to). Point and
        /// say is not offered there: the Option-click reaches the page.
        case foreign
    }

    static func scope(currentURL: String?, address: URL) -> PageScope {
        guard let currentURL, let got = URLComponents(string: currentURL),
              let want = URLComponents(url: address, resolvingAgainstBaseURL: false),
              let scheme = ShowSpec.canonicalScheme(got.scheme), scheme == ShowSpec.canonicalScheme(want.scheme),
              let host = got.host?.lowercased(), !host.isEmpty, host == want.host?.lowercased(),
              got.port == want.port else { return .foreign }
        return ShowLoadJudge.isShownPage(currentURL, address: address) ? .shown : .sameSource
    }

    /// A page's address without its fragment: a hash change is the same
    /// document; anything else is another one.
    static func documentKey(_ url: String?) -> String? {
        guard let url, var parts = URLComponents(string: url) else { return nil }
        parts.fragment = nil
        return parts.string
    }

    /// Whether pending work may still capture or store a screenshot: the
    /// viewer shows the same document it was read from, not loading, in scope.
    static func isSameDocument(pending: String?, current: String?, isLoading: Bool, address: URL) -> Bool {
        guard !isLoading, let pending, let key = documentKey(current), key == pending else { return false }
        return scope(currentURL: current, address: address) != .foreign
    }

    /// The `screenshot:` line when none was taken because the page has
    /// embedded content (another document in a frame, embed or object).
    static let screenshotOmittedEmbedded = "omitted (the page has embedded content)"

    /// The fixed line above the field: who the note goes to, and where it runs.
    static func recipientLine(title: String, machine: String) -> String {
        String(format: String(localized: "show.point.recipient", defaultValue: "To %@ · %@"), title, machine)
    }

    /// The mail body the agent reads. `page:` is the page the operator
    /// pointed at, read from the page itself; a page other than the shown one
    /// says so and names the shown address.
    static func body(line: String, element: Element, address: String, screenshot: String?,
                     scope: PageScope = .shown) -> String {
        var lines = [line.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        let page = element.url.isEmpty ? address + element.hash : element.url
        lines.append("page: \(page)")
        if scope != .shown { lines.append("note: not the shown page; shown: \(address)") }
        lines.append("element: \(element.selector) <\(element.tag)>")
        if !element.text.isEmpty { lines.append("text: \(element.text.replacingOccurrences(of: "\n", with: " "))") }
        lines.append("screenshot: \(screenshot ?? "(none)")")
        var body = lines.joined(separator: "\n")
        while body.utf8.count > MailboxEnvelope.maxBodyBytes { body = String(body.dropLast(64)) }
        return body
    }

    /// The viewport rect (in view points) to crop: the element plus a margin,
    /// clamped to the view.
    static func cropRect(element: CGRect, zoom: CGFloat, bounds: CGRect, margin: CGFloat = 12) -> CGRect {
        let scaled = CGRect(x: element.minX * zoom, y: element.minY * zoom, width: element.width * zoom, height: element.height * zoom)
        let padded = scaled.insetBy(dx: -margin, dy: -margin).intersection(bounds)
        return padded.isNull || padded.isEmpty ? bounds : padded
    }

    /// Writes the mail into the outbox of the workspace that holds the
    /// showing panel now, addressed to its exact panel UUID.
    @discardableResult
    static func mail(to panel: UUID, workspace: UUID, body: String, stateURL: URL) throws -> String {
        let envelope = try MailboxEnvelope.build(from: sender, to: MailboxAddress.idPrefix + panel.uuidString,
                                                 topic: topic, body: body)
        let outbox = MailboxLayout.outboxURL(state: stateURL, workspaceId: workspace)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try MailboxIO.atomicWrite(data: try envelope.encode(),
                                  to: outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id)))
        return envelope.id
    }

    /// What became of a written note, from the dispatcher's own per-message
    /// record (the one `c11 mailbox status` reads). Success is only ever a
    /// recipient copy that landed for the showing panel, never an absence.
    enum Delivery: Equatable {
        /// Not dispatched yet, or dispatched with no result for the panel yet.
        case pending
        /// A copy landed in the showing panel's inbox.
        case delivered
        /// The dispatcher refused it (its reason).
        case rejected(String)
        /// The dispatcher took it but could not write the panel's inbox.
        case copyFailed
    }

    static func delivery(id: String, stateURL: URL) -> Delivery {
        let root = stateURL.appendingPathComponent(MailboxLayout.workspacesDirectoryName, isDirectory: true)
        guard let report = try? MailboxReceiptStatus.status(id: id, workspacesRoot: root) else { return .pending }
        switch report.state {
        case .queued:
            return .pending
        case .rejected:
            return .rejected(report.rejectedReason ?? "")
        case .sent:
            // The note names one panel (`id:<uuid>`), so every recipient row
            // is the dispatcher's mapping of that one address: the panel
            // itself, or its session's mailbox owner (a shared session).
            let rows = report.recipients
            if rows.contains(where: { $0.sentAt != nil && !$0.copyFailed }) { return .delivered }
            if !rows.isEmpty, rows.allSatisfy(\.copyFailed) { return .copyFailed }
            return .pending
        }
    }

    /// The operator-facing reason for a rejection.
    static func rejectionText(_ reason: String) -> String {
        reason.hasPrefix("no live panel") || reason.isEmpty ? Text.agentGone : reason
    }

    /// The operator-facing reason for a definite failure; nil for a
    /// delivery and for a note still on its way.
    static func failureText(_ outcome: Delivery) -> String? {
        switch outcome {
        case .delivered, .pending: return nil
        case .rejected(let reason): return rejectionText(reason)
        case .copyFailed: return Text.copyFailed
        }
    }

    /// Whether the operator may send the same words again: only after the
    /// dispatcher definitely did not deliver them, so no note is ever doubled.
    static func mayRetry(_ outcome: Delivery) -> Bool {
        switch outcome {
        case .rejected, .copyFailed: return true
        case .delivered, .pending: return false
        }
    }

    /// Where a note's final answer is said, and what it says.
    enum Surface: Equatable {
        /// In the note's own composer, still open; `retry` re-enables the field.
        case composer(String, retry: Bool)
        /// On the viewer's page: the composer was closed before the answer.
        case page(String, sticky: Bool)
    }

    /// The final answer for a note, or nil while it is still on its way.
    static func surface(for outcome: Delivery, composerOpen: Bool, title: String, line: String) -> Surface? {
        if outcome == .pending { return nil }
        guard let failure = failureText(outcome) else {
            return composerOpen ? .composer(Text.sent(title), retry: false) : .page(Text.lateDelivered(title), sticky: false)
        }
        return composerOpen ? .composer(Text.notSent(failure), retry: mayRetry(outcome))
            : .page(Text.lateFailure(title, failure, line), sticky: true)
    }

    /// Every line the composer and the viewer's bar say (C11H-247).
    enum Text {
        static var agentGone: String {
            String(localized: "show.point.agentGone", defaultValue: "The agent that showed this has closed. Nothing can be sent.")
        }
        static func sending(_ title: String) -> String {
            String(format: String(localized: "show.point.sending", defaultValue: "Sending to %@…"), title)
        }
        static func sent(_ title: String) -> String {
            String(format: String(localized: "show.point.sent", defaultValue: "Sent to %@"), title)
        }
        static func queued(_ title: String) -> String {
            String(format: String(localized: "show.point.queued", defaultValue: "Written for %@; not delivered yet"), title)
        }
        static func notSent(_ reason: String) -> String {
            String(format: String(localized: "show.point.notSent", defaultValue: "Not sent: %@"), reason)
        }
        static var copyFailed: String {
            String(localized: "show.point.copyFailed", defaultValue: "the agent's inbox could not be written")
        }
        static var pageChanged: String {
            String(localized: "show.point.pageChanged", defaultValue: "The page changed. Option-click again to point at it.")
        }
        static func lateFailure(_ title: String, _ reason: String, _ note: String) -> String {
            String(format: String(localized: "show.point.lateFailure", defaultValue: "Your note to %@ was not sent: %@. It said: %@"),
                   title, reason, note)
        }
        static func lateDelivered(_ title: String) -> String {
            String(format: String(localized: "show.point.lateDelivered", defaultValue: "Your note to %@ was delivered."), title)
        }
        static var offShownPage: String {
            String(localized: "show.point.offShownPage", defaultValue: "This is not the shown page; the note says so.")
        }
    }
}

/// The interactive half: element read, the one-line field, the screenshot and the send.
@MainActor
final class ShowPointAndSayController: NSObject, NSTextFieldDelegate, NSPopoverDelegate {
    static let shared = ShowPointAndSayController()
    private var popover: NSPopover?
    @MainActor private final class Pending {
        let session: ShowViewerSession
        let panelID: UUID
        let element: ShowPointAndSay.Element
        let webView: WKWebView
        let scope: ShowPointAndSay.PageScope
        /// The document the element was read from (address without fragment).
        let document: String?
        /// The main-frame document generation it was read from.
        let generation: Int
        weak var field: NSTextField?
        weak var recipient: NSTextField?
        weak var status: NSTextField?
        var sending = false
        /// Set once the page moved on: nothing from this note is captured,
        /// stored or pushed any more.
        var stale = false
        var observers: [NSKeyValueObservation] = []
        let token = UUID()

        init(session: ShowViewerSession, panelID: UUID, element: ShowPointAndSay.Element, webView: WKWebView,
             scope: ShowPointAndSay.PageScope) {
            self.session = session; self.panelID = panelID; self.element = element
            self.webView = webView; self.scope = scope
            self.document = ShowPointAndSay.documentKey(element.url.isEmpty ? webView.url?.absoluteString : element.url)
            self.generation = session.documentGeneration
        }
    }
    private var pending: Pending?
    /// Notes written and still waiting for the dispatcher's answer, by
    /// token, each with its delivery task; a closed viewer ends its notes.
    private let inFlight = ShowNoteTracker<Pending>()
    /// How long a sent note's confirmation stays before the popover closes.
    nonisolated static let confirmSeconds: TimeInterval = 1.5
    /// How long c11 waits for the dispatcher's answer for one note. The
    /// note stays on screen, unsendable again, until an answer or this.
    nonisolated static let deliveryWatchSeconds: TimeInterval = 120
    /// After this long without an answer the composer says the note is
    /// written but not delivered yet (still watching).
    nonisolated static let slowNoticeSeconds: TimeInterval = 3
    /// How long a composer whose page moved on stays to be read.
    nonisolated static let staleCloseSeconds: TimeInterval = 4

    /// Called from the web view's own mouse-down. Returns whether the click
    /// was taken (it then never reaches the page). A page outside the shown
    /// source is not offered: the click reaches the page as any click does.
    func click(webView: CmuxWebView, event: NSEvent) -> Bool {
        guard let panelID = ShowViewerController.shared.panelID(for: webView),
              let session = ShowViewerController.shared.session(panel: panelID),
              ShowPointAndSay.accepts(type: event.type, modifiers: event.modifierFlags, isViewer: true) else { return false }
        let scope = ShowPointAndSay.scope(currentURL: webView.url?.absoluteString, address: session.address)
        guard scope != .foreign, !webView.isLoading else { return false }
        let clickedDocument = ShowPointAndSay.documentKey(webView.url?.absoluteString)
        let clickedGeneration = session.documentGeneration
        let point = webView.convert(event.locationInWindow, from: nil)
        let zoom = max(0.1, webView.pageZoom * webView.magnification)
        let y = webView.isFlipped ? point.y : webView.bounds.height - point.y
        let css = CGPoint(x: point.x / zoom, y: y / zoom)
        webView.callAsyncJavaScript(ShowPointAndSay.elementScript, arguments: ["x": css.x, "y": css.y],
                                    in: nil, in: .defaultClient) { [weak self, weak webView, weak session] result in
            MainActor.assumeIsolated {
                guard let self, let webView, let session,
                      let element = ShowPointAndSay.Element(try? result.get()) else { NSSound.beep(); return }
                // The element must come from the document that was clicked,
                // and the viewer must still show it.
                let read = ShowPointAndSay.documentKey(element.url.isEmpty ? webView.url?.absoluteString : element.url)
                guard read == clickedDocument, session.documentGeneration == clickedGeneration,
                      ShowPointAndSay.isSameDocument(pending: read, current: webView.url?.absoluteString,
                                                     isLoading: webView.isLoading, address: session.address) else {
                    NSSound.beep(); return
                }
                let scope = ShowPointAndSay.scope(currentURL: element.url.isEmpty ? webView.url?.absoluteString : element.url,
                                                  address: session.address)
                self.prompt(Pending(session: session, panelID: panelID, element: element, webView: webView, scope: scope),
                            at: point)
            }
        }
        return true
    }

    private static func label(_ text: String, font: NSFont, color: NSColor, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = color
        label.font = font
        label.frame = NSRect(x: 12, y: y, width: 360, height: 16)
        return label
    }

    private func prompt(_ next: Pending, at point: NSPoint) {
        if popover != nil, pending?.sending == true {
            // A note still on its way keeps its composer; no second one over it.
            NSSound.beep()
            return
        }
        popover?.close()
        let content: NSView
        switch ShowViewerController.shared.callerState(next.session) {
        case .gone:
            // Said before anything is typed, and nothing is offered to send.
            content = NSView(frame: NSRect(x: 0, y: 0, width: 384, height: 52))
            let gone = Self.label(ShowPointAndSay.Text.agentGone, font: .systemFont(ofSize: 12, weight: .semibold),
                                  color: .systemRed, y: 26)
            gone.setAccessibilityIdentifier("show.point.gone")
            content.addSubview(gone)
            content.addSubview(Self.label(next.element.selector, font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                          color: .secondaryLabelColor, y: 8))
        case .live(_, let title):
            content = NSView(frame: NSRect(x: 0, y: 0, width: 384, height: 104))
            // The recipient stays above the field for the whole time the
            // operator types; the placeholder alone vanished on a keystroke.
            let to = Self.label(ShowPointAndSay.recipientLine(title: title, machine: ShowViewerController.machineLabel(next.session.origin)),
                                font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor, y: 80)
            to.setAccessibilityIdentifier("show.point.recipient")
            next.recipient = to
            content.addSubview(to)
            content.addSubview(Self.label(next.element.selector, font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                          color: .secondaryLabelColor, y: 60))
            let input = NSTextField(string: "")
            input.placeholderString = String(format: String(localized: "show.point.placeholder",
                                                            defaultValue: "Say something to %@ about this"), title)
            input.delegate = self
            // Return sends: the field's own action, the standard path for Return.
            input.target = self
            input.action = #selector(submit(_:))
            input.frame = NSRect(x: 12, y: 30, width: 360, height: 24)
            input.setAccessibilityIdentifier("show.point.field")
            content.addSubview(input)
            next.field = input
            let line = Self.label(next.scope == .shown ? "" : ShowPointAndSay.Text.offShownPage,
                                  font: .systemFont(ofSize: 11), color: .secondaryLabelColor, y: 8)
            line.setAccessibilityIdentifier("show.point.status")
            content.addSubview(line)
            next.status = line
        }
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        self.popover = popover
        pending = next
        watchDocument(next)
        popover.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: next.webView, preferredEdge: .maxY)
        // The field lives in the popover's own window.
        if let field = next.field {
            field.window?.makeKeyAndOrderFront(nil)
            field.window?.makeFirstResponder(field)
        }
    }

    /// A load starting, or the address moving to another document, ends
    /// what this note may capture. KVO fires on main for a web view.
    private func watchDocument(_ note: Pending) {
        let check: () -> Void = { [weak self, weak note] in
            MainActor.assumeIsolated {
                guard let self, let note, !note.stale else { return }
                if !self.isCurrent(note) { self.invalidate(note) }
            }
        }
        note.observers = [
            note.webView.observe(\.isLoading, options: [.new]) { _, _ in check() },
            note.webView.observe(\.url, options: [.new]) { _, _ in check() },
        ]
    }

    /// Whether the note's page is still what the viewer shows.
    private func isCurrent(_ note: Pending) -> Bool {
        guard !note.stale, ShowViewerController.shared.panelID(for: note.webView) == note.panelID,
              note.session.documentGeneration == note.generation else { return false }
        return ShowPointAndSay.isSameDocument(pending: note.document, current: note.webView.url?.absoluteString,
                                              isLoading: note.webView.isLoading, address: note.session.address)
    }

    /// The page moved on. A note not yet written is dropped (no capture, no
    /// mail); one already sending keeps only its delivery watch.
    private func invalidate(_ note: Pending) {
        note.stale = true
        note.observers = []
        guard !note.sending else { return }
        note.field?.isEnabled = false
        note.status?.textColor = .systemOrange
        note.status?.stringValue = ShowPointAndSay.Text.pageChanged
        // With its field off nothing in it takes Escape: it closes itself
        // once read, so it never sits over the page it no longer describes.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.staleCloseSeconds) { [weak self, weak note] in
            MainActor.assumeIsolated {
                guard let self, let note, self.pending === note, !note.sending else { return }
                self.popover?.close()
            }
        }
    }

    @objc private func submit(_ sender: NSTextField) {
        guard let current = pending, !current.sending else { return }
        let line = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        guard isCurrent(current) else { invalidate(current); return }
        // Checked again at send: the agent may have closed while he typed.
        switch ShowViewerController.shared.callerState(current.session) {
        case .gone:
            sender.isEnabled = false
            current.recipient?.stringValue = ShowPointAndSay.Text.agentGone
            current.recipient?.textColor = .systemRed
            current.status?.stringValue = ""
        case .live(let workspace, let title):
            current.sending = true
            sender.isEnabled = false
            current.status?.textColor = .secondaryLabelColor
            current.status?.stringValue = ShowPointAndSay.Text.sending(title)
            send(current, line: line, workspace: workspace, title: title)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if let field = control as? NSTextField { submit(field) }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            popover?.close()
            return true
        }
        return false
    }

    /// The viewer closed: its notes still waiting stop being followed and
    /// release the viewer. Each was written once; nothing is sent again, and
    /// the dispatcher's own record still says what became of it.
    func viewerClosed(_ viewer: UUID) {
        if let note = pending, note.panelID == viewer {
            note.observers = []
            pending = nil
            popover?.close()
        }
        inFlight.viewerClosed(viewer)
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        // A note still on its way keeps watching; its late failure is said
        // on the page instead (see `finish`).
        if let note = pending, !note.sending { note.observers = [] }
        pending = nil
    }

    private func send(_ note: Pending, line: String, workspace: UUID, title: String) {
        inFlight.track(note.token, note: note, viewer: note.panelID)
        let token = note.token
        let element = note.element
        let caller = note.session.caller
        let address = note.session.address.absoluteString.components(separatedBy: "#").first ?? note.session.address.absoluteString
        let origin = note.session.origin
        let scope = note.scope
        let webView = note.webView
        // Write the mail with the screenshot once it is known to be of this page.
        let write: @MainActor (Data?, String?) -> Void = { png, screenshotLine in
            let task = Task.detached(priority: .userInitiated) {
                let screenshot: String?
                if let screenshotLine { screenshot = screenshotLine } else { screenshot = await Self.store(png: png, origin: origin) }
                let body = ShowPointAndSay.body(line: line, element: element, address: address, screenshot: screenshot, scope: scope)
                let outcome: ShowPointAndSay.Delivery
                do {
                    let state = try MailboxLayout.defaultStateURL()
                    let id = try ShowPointAndSay.mail(to: caller, workspace: workspace, body: body, stateURL: state)
                    let slow = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(Self.slowNoticeSeconds * 1_000_000_000))
                        Self.shared.slow(token, title: title)
                    }
                    outcome = await Self.followDelivery {
                        ShowPointAndSay.delivery(id: id, stateURL: state)
                    }
                    slow.cancel()
                } catch {
                    NSLog("c11.show.point mail_failed panel=%@ error=%@", caller.uuidString, String(describing: error))
                    outcome = .rejected(error.localizedDescription)
                }
                // A closed viewer cancelled this note: nothing more is said.
                guard !Task.isCancelled else { return }
                await MainActor.run { Self.shared.finish(token, outcome, title: title, line: line) }
            }
            Self.shared.inFlight.attach(task, to: token)
        }
        // First guard: WebKit already reported a frame in this document
        // (frames in closed shadow roots included).
        guard !note.session.hasEmbeddedContent(webView.url?.absoluteString) else {
            write(nil, ShowPointAndSay.screenshotOmittedEmbedded)
            return
        }
        // Second guard, fresh, immediately before the capture.
        webView.callAsyncJavaScript(ShowPointAndSay.embeddedContentScript, arguments: [:], in: nil,
                                    in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, !note.stale, self.isCurrent(note) else { write(nil, nil); return }
                // Anything but a clear "no" (an error, a page that would not answer) is a yes.
                let embedded = (try? result.get()) as? Bool ?? true
                if embedded || note.session.hasEmbeddedContent(webView.url?.absoluteString) {
                    write(nil, ShowPointAndSay.screenshotOmittedEmbedded)
                    return
                }
                self.capture(note, write: write)
            }
        }
    }

    private func capture(_ note: Pending, write: @escaping @MainActor (Data?, String?) -> Void) {
        let webView = note.webView
        let zoom = max(0.1, webView.pageZoom * webView.magnification)
        let config = WKSnapshotConfiguration()
        config.rect = ShowPointAndSay.cropRect(element: note.element.rect, zoom: zoom, bounds: webView.bounds)
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                // Checked again after the capture: a navigation that raced
                // it leaves the note with no picture at all, and a frame
                // WebKit reported meanwhile drops the picture.
                guard let self, !note.stale, self.isCurrent(note) else {
                    write(nil, nil)
                    return
                }
                guard !note.session.hasEmbeddedContent(webView.url?.absoluteString) else {
                    write(nil, ShowPointAndSay.screenshotOmittedEmbedded)
                    return
                }
                let png = image.flatMap { image -> Data? in
                    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
                    return rep.representation(using: .png, properties: [:])
                }
                write(png, nil)
            }
        }
    }

    /// How a written note's answer is awaited: closely at first, then
    /// slowly, then every `deliveryTailInterval` for as long as c11 runs.
    /// Running out of the phases is not a failure and drops nothing: the
    /// note is still on its way and is never sent a second time.
    nonisolated static let deliveryPhases: [(seconds: TimeInterval, interval: TimeInterval)] = [
        (deliveryWatchSeconds, 0.2), (3600, 5),
    ]
    nonisolated static let deliveryTailInterval: TimeInterval = 30

    /// Off main: polls `probe` through each phase, then with no deadline,
    /// until the dispatcher's definite answer for the note.
    nonisolated static func followDelivery(phases: [(seconds: TimeInterval, interval: TimeInterval)] = deliveryPhases,
                                           tailInterval: TimeInterval = deliveryTailInterval,
                                           probe: @escaping @Sendable () -> ShowPointAndSay.Delivery) async -> ShowPointAndSay.Delivery {
        for phase in phases {
            let delivery = await watchDelivery(seconds: phase.seconds, interval: phase.interval, probe: probe)
            if delivery != .pending || Task.isCancelled { return delivery }
        }
        while !Task.isCancelled {
            let delivery = probe()
            if delivery != .pending { return delivery }
            do { try await Task.sleep(nanoseconds: UInt64(tailInterval * 1_000_000_000)) } catch { break }
        }
        return .pending
    }

    /// Off main: polls `probe` until a terminal answer or `seconds`.
    nonisolated static func watchDelivery(seconds: TimeInterval = deliveryWatchSeconds, interval: TimeInterval = 0.2,
                                          probe: @escaping @Sendable () -> ShowPointAndSay.Delivery) async -> ShowPointAndSay.Delivery {
        let deadline = Date().addingTimeInterval(seconds)
        while !Task.isCancelled {
            let delivery = probe()
            if delivery != .pending || Date() >= deadline { return delivery }
            do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) } catch { break }
        }
        return .pending
    }

    /// No answer yet after a few seconds: say so, and keep watching.
    private func slow(_ token: UUID, title: String) {
        guard let note = inFlight.note(token), pending === note, note.sending else { return }
        note.status?.stringValue = ShowPointAndSay.Text.queued(title)
    }

    /// Says what became of the note once the dispatcher answered: in its
    /// composer while open (a delivery closes it after a moment; a definite
    /// failure keeps the text to retry), else on the viewer's page, a failure
    /// with the note's own words. Only a definite answer reaches here.
    private func finish(_ token: UUID, _ outcome: ShowPointAndSay.Delivery, title: String, line: String) {
        guard let note = inFlight.note(token) else { return }
        let open = pending === note && popover != nil
        guard let surface = ShowPointAndSay.surface(for: outcome, composerOpen: open, title: title, line: line) else {
            // Not an answer: the note stays tracked and unsendable again.
            if open { note.status?.stringValue = ShowPointAndSay.Text.queued(title) }
            return
        }
        inFlight.finish(token)
        note.sending = false
        switch surface {
        case .page(let text, let sticky):
            note.observers = []
            (note.webView as? CmuxWebView)?.panelLinkActivation?.showText(text, sticky: sticky)
            NSLog("c11.show.point late_result panel=%@ delivered=%@", note.session.caller.uuidString,
                  ShowPointAndSay.failureText(outcome) == nil ? "yes" : "no")
        case .composer(let text, let retry):
            guard let popover else { return }
            note.status?.stringValue = text
            if ShowPointAndSay.failureText(outcome) == nil {
                note.status?.textColor = .secondaryLabelColor
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmSeconds) { [weak popover] in
                    popover?.close()
                }
                return
            }
            note.status?.textColor = .systemRed
            // A retry only after a definite failure, and only on this same page.
            guard retry else { return }
            if note.stale || !isCurrent(note) {
                invalidate(note)
                note.status?.stringValue = text
                return
            }
            note.field?.isEnabled = true
            // Disabling the field gave up its focus: hand it back for a retry.
            if let field = note.field { field.window?.makeFirstResponder(field) }
        }
    }

    /// Where the agent can read the screenshot: on its own machine when c11
    /// can write there, else on this Mac (said so in the path line).
    nonisolated static func store(png: Data?, origin: ShowOrigin, hosts: ShowHosts = .shared,
                                  name: String = "\(UUID().uuidString.lowercased()).png") async -> String? {
        guard let png else { return nil }
        if case .remote(let machine, let container, let ref) = origin, let link = ref.flatMap({ hosts.link(for: $0) }),
           let hostPath = try? await link.host.showWriteFile(machine: machine, path: ShowShots.hostRelativePath(name), data: png) {
            guard let container else { return hostPath }
            // A container agent cannot read the host: push the file into its
            // container, every argv fixed and literal, and name that path.
            let push = ShowShots.pushArgv(hostPath: hostPath, container: container, name: name)
            let pushed = try? await link.host.showExec(machine: machine, argv: push, timeout: 15)
            _ = try? await link.host.showExec(machine: machine, argv: ShowShots.removeArgv(hostPath: hostPath), timeout: 10)
            if pushed?.code == 0 { return ShowShots.containerPath(name) }
        }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("c11/show/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(name)
        guard (try? png.write(to: url, options: .atomic)) != nil else { return nil }
        return origin.isRemote ? url.path + " (on the operator's Mac)" : url.path
    }
}

/// The notes a viewer has in flight (C11H-247): each note with its viewer
/// and its delivery task, until the dispatcher answers or the viewer closes.
@MainActor
final class ShowNoteTracker<Note: AnyObject> {
    private struct Entry {
        let note: Note
        let viewer: UUID
        var task: Task<Void, Never>?
    }
    private var entries: [UUID: Entry] = [:]

    var count: Int { entries.count }

    func track(_ token: UUID, note: Note, viewer: UUID) {
        entries[token] = Entry(note: note, viewer: viewer, task: nil)
    }

    func attach(_ task: Task<Void, Never>, to token: UUID) {
        guard entries[token] != nil else { task.cancel(); return }
        entries[token]?.task = task
    }

    func note(_ token: UUID) -> Note? { entries[token]?.note }

    /// The note got its answer: forget it.
    func finish(_ token: UUID) { entries.removeValue(forKey: token) }

    /// The viewer closed: cancel and forget every note it had in flight.
    func viewerClosed(_ viewer: UUID) {
        for (token, entry) in entries where entry.viewer == viewer {
            entry.task?.cancel()
            entries.removeValue(forKey: token)
        }
    }
}

/// Where point-and-say screenshots go on an agent's machine, and the only
/// `machine.exec` shapes and `file.write` path a show may use (C11H-228).
enum ShowShots {
    static let hostFolder = ".local/share/c11/show/shots"
    static let containerFolder = "/tmp/c11-show/shots"

    static func hostRelativePath(_ name: String) -> String { hostFolder + "/" + name }
    static func containerPath(_ name: String) -> String { containerFolder + "/" + name }

    static func isShotName(_ name: String) -> Bool {
        name.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png$"#, options: .regularExpression) != nil
    }

    static func pushArgv(hostPath: String, container: String, name: String) -> [String] {
        ["incus", "file", "push", "--create-dirs", "--mode", "0644", "--", hostPath, container + containerPath(name)]
    }

    static func removeArgv(hostPath: String) -> [String] { ["rm", "-f", "--", hostPath] }
}

/// The session's gate on `machine.exec` and `file.write` (C11H-228): the
/// relay session runs only what `c11 show` builds. A later caller cannot
/// inherit an open exec.
enum ShowExecGate {
    static let statOptions: [[String]] = ShowHCFetcher.StatFlavor.allCases.map(\.options)

    static func allows(method: String, params: [String: HCJSONValue]) -> Bool {
        switch method {
        case "machine.exec":
            guard params["line"] == nil || params["line"] == .null, params["input"] == nil || params["input"] == .null,
                  params["env"] == nil || params["env"] == .null || params["env"] == .object([:]),
                  params["cwd"] == nil || params["cwd"] == .null,
                  let argv = params["argv"]?.array?.compactMap(\.string), argv.count == params["argv"]?.array?.count else { return false }
            return allowsArgv(argv)
        case "file.write":
            guard let path = params["path"]?.string, params["cwd"] == nil || params["cwd"] == .null else { return false }
            let name = String(path.dropFirst(ShowShots.hostFolder.count + 1))
            return path.hasPrefix(ShowShots.hostFolder + "/") && isShot(name)
        default:
            return true
        }
    }

    private static func isShot(_ name: String) -> Bool { ShowShots.isShotName(name) }

    /// `[incus exec <container> --] realpath|stat <fixed opts>|cat -- <absolute path>`,
    /// the screenshot push into a container, or removing a shot on the host.
    static func allowsArgv(_ argv: [String]) -> Bool {
        if argv.count == 9, Array(argv[0..<7]) == ["incus", "file", "push", "--create-dirs", "--mode", "0644", "--"] {
            let host = argv[7], target = argv[8]
            guard let slash = target.firstIndex(of: "/") else { return false }
            let container = String(target[..<slash]), inside = String(target[slash...])
            return isHostShot(host) && ShowOrigin.isContainerName(container)
                && inside.hasPrefix(ShowShots.containerFolder + "/") && isShot(String(inside.dropFirst(ShowShots.containerFolder.count + 1)))
        }
        if argv.count == 4, Array(argv[0..<3]) == ["rm", "-f", "--"] { return isHostShot(argv[3]) }
        var command = argv[...]
        if argv.count > 4, argv[0] == "incus", argv[1] == "exec", argv[3] == "--" {
            guard ShowOrigin.isContainerName(argv[2]) else { return false }
            command = argv[4...]
        }
        let words = Array(command)
        guard words.count >= 3, words[words.count - 2] == "--", words.last!.hasPrefix("/") else { return false }
        let options = Array(words[1..<(words.count - 2)])
        switch words[0] {
        case "realpath", "cat": return options.isEmpty
        case "stat": return statOptions.contains(options)
        default: return false
        }
    }

    private static func isHostShot(_ path: String) -> Bool {
        guard path.hasPrefix("/"), let range = path.range(of: "/" + ShowShots.hostFolder + "/") else { return false }
        let name = String(path[range.upperBound...])
        return isShot(name) && !path.contains("/../")
    }
}
