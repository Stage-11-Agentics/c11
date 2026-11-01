import XCTest
import AppKit
import WebKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-510: a page cannot hand a non-web URL to another app without the
/// operator's consent.
@MainActor
final class BrowserExternalOpenGateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var clock: TimeInterval = 100
    private var opened: [URL] = []
    private var presented: [BrowserExternalOpenGate.Prompt] = []
    private var answers: [(BrowserExternalOpenGate.Answer) -> Void] = []
    private var notices: [String] = []
    private var logs: [String] = []
    private var operatorInput = true
    private var dismissed = 0
    private var visible = true
    private var handler: String? = "Screen Sharing"

    override func setUp() {
        super.setUp()
        suiteName = "c11.tests.external-open.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = 100
        opened = []
        presented = []
        answers = []
        notices = []
        logs = []
        operatorInput = true
        dismissed = 0
        visible = true
        handler = "Screen Sharing"
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeGate() -> BrowserExternalOpenGate {
        BrowserExternalOpenGate(
            appName: { [unowned self] _ in self.handler },
            open: { [unowned self] url in self.opened.append(url); return true },
            now: { [unowned self] in self.clock },
            defaults: defaults
        )
    }

    private var host: BrowserExternalOpenHost {
        BrowserExternalOpenHost(
            isVisible: { [unowned self] in self.visible },
            present: { [unowned self] prompt, answer in
                self.presented.append(prompt)
                self.answers.append(answer)
                return { [unowned self] in self.dismissed += 1 }
            },
            notice: { [unowned self] in self.notices.append($0) },
            log: { [unowned self] in self.logs.append($0) },
            owner: ownerID,
            recentOperatorInput: { [unowned self] in self.operatorInput }
        )
    }

    private let ownerObject = NSObject()
    private var ownerID: ObjectIdentifier { ObjectIdentifier(ownerObject) }
    private let page = BrowserExternalOpenOrigin(scheme: "https", host: "example.com", port: 443)
    private let vnc = URL(string: "vnc://c11-fixture.invalid")!
    private let smb = URL(string: "smb://c11-fixture.invalid/share")!

    func testPageSMBRequestAsksAndOpensNothingUntilAnswered() {
        let gate = makeGate()
        XCTAssertEqual(gate.request(smb, origin: page, userClick: false, host: host), .prompted)
        XCTAssertEqual(opened, [])
        XCTAssertEqual(presented.map(\.url), [smb])
        XCTAssertEqual(presented.first?.origin.host, "example.com")
        XCTAssertEqual(presented.first?.appName, "Screen Sharing")
    }

    func testCancelOpensNothingAndOpenOpensExactlyOnce() {
        let gate = makeGate()
        gate.request(vnc, origin: page, userClick: true, host: host)
        answers[0](.cancel)
        answers[0](.open(alwaysAllow: false))
        XCTAssertEqual(opened, [], "a stale answer after Cancel must not open")

        clock += 3
        gate.request(vnc, origin: page, userClick: true, host: host)
        answers[1](.open(alwaysAllow: false))
        answers[1](.open(alwaysAllow: false))
        XCTAssertEqual(opened, [vnc])
        XCTAssertFalse(BrowserExternalSchemeSettings.isAllowed(originKey: "https://example.com", scheme: "vnc", defaults: defaults))
    }

    func testAlwaysAllowOpensThatPairWithoutAskingUntilRevoked() {
        let gate = makeGate()
        gate.request(vnc, origin: page, userClick: true, host: host)
        answers[0](.open(alwaysAllow: true))
        XCTAssertEqual(defaults.string(forKey: BrowserExternalSchemeSettings.allowlistKey), "https://example.com vnc")

        XCTAssertEqual(gate.request(vnc, origin: page, userClick: false, host: host), .openedAllowed)
        XCTAssertEqual(opened, [vnc, vnc])
        XCTAssertEqual(presented.count, 1)

        // Another scheme from the same site, or the same scheme from another site, still asks.
        clock += 3
        XCTAssertEqual(gate.request(smb, origin: page, userClick: true, host: host), .prompted)
        answers[1](.cancel)
        clock += 3
        let other = BrowserExternalOpenOrigin(scheme: "https", host: "other.example", port: nil)
        XCTAssertEqual(gate.request(vnc, origin: other, userClick: true, host: host), .prompted)
        answers[2](.cancel)

        // Revoke: the operator deletes the line in Settings.
        defaults.set("", forKey: BrowserExternalSchemeSettings.allowlistKey)
        clock += 3
        XCTAssertEqual(gate.request(vnc, origin: page, userClick: true, host: host), .prompted)
        XCTAssertEqual(opened, [vnc, vnc])
    }

    func testRequestsWhilePendingOrCoolingDownAreDroppedNotQueued() {
        let gate = makeGate()
        XCTAssertEqual(gate.request(vnc, origin: page, userClick: true, host: host), .prompted)
        for _ in 0..<20 {
            XCTAssertEqual(gate.request(smb, origin: page, userClick: true, host: host), .droppedPending)
        }
        XCTAssertEqual(presented.count, 1)
        answers[0](.cancel)
        XCTAssertEqual(gate.request(vnc, origin: page, userClick: true, host: host), .droppedCooldown)
        clock += BrowserExternalOpenGate.cooldown + 0.1
        // After Cancel a script cannot ask again for the same pair; a click can.
        XCTAssertEqual(gate.request(vnc, origin: page, userClick: false, host: host), .droppedDeclined)
        XCTAssertEqual(gate.request(vnc, origin: page, userClick: true, host: host), .prompted)
        answers[1](.cancel)
        clock += 3
        gate.pageDidNavigate()
        XCTAssertEqual(gate.request(vnc, origin: page, userClick: false, host: host), .prompted)
        XCTAssertEqual(opened, [])
    }

    func testDroppedRequestsLeaveOneOperatorLogLinePerReasonAndWindow() {
        visible = false
        let gate = makeGate()
        for _ in 0..<5 { gate.request(vnc, origin: page, userClick: false, host: host) }
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("example.com") && logs[0].contains("vnc:") && logs[0].contains("hidden"), logs[0])

        visible = true
        gate.request(vnc, origin: page, userClick: true, host: host)
        for _ in 0..<5 { gate.request(vnc, origin: page, userClick: true, host: host) }
        answers[0](.cancel)
        for _ in 0..<5 { gate.request(vnc, origin: page, userClick: true, host: host) }
        XCTAssertEqual(logs.count, 3, "hidden, pending and cooldown: one line each")

        clock += BrowserExternalOpenGate.dropLogInterval + 1
        gate.pageDidNavigate()
        visible = false
        XCTAssertEqual(gate.request(vnc, origin: page, userClick: false, host: host), .droppedHidden)
        XCTAssertEqual(logs.count, 4, "a new window allows one more line")
        XCTAssertEqual(opened, [])
    }

    /// Fable B2: WebKit reports a scripted `element.click()` as a link
    /// activation. Without real operator input it is a script, not a click.
    func testScriptedClickWithoutOperatorInputCannotReaskAfterCancel() {
        let gate = makeGate()
        gate.request(vnc, origin: page, userClick: true, host: host)
        answers[0](.cancel)
        clock += BrowserExternalOpenGate.cooldown + 0.1
        operatorInput = false
        for _ in 0..<5 {
            XCTAssertEqual(gate.request(vnc, origin: page, userClick: true, host: host), .droppedDeclined)
            clock += BrowserExternalOpenGate.cooldown + 0.1
        }
        XCTAssertEqual(presented.count, 1)
        operatorInput = true
        XCTAssertEqual(gate.request(vnc, origin: page, userClick: true, host: host), .prompted,
                       "a real click may ask again")
    }

    /// Fable B1: the asker going away must clear the gate, not wedge it.
    func testCancelPendingClearsOnlyTheOwnersPromptAndDismissesIt() {
        let gate = makeGate()
        gate.request(vnc, origin: page, userClick: true, host: host)
        XCTAssertFalse(gate.cancelPending(owner: ObjectIdentifier(NSObject())), "another web view's close")
        XCTAssertNotNil(gate.pending)
        XCTAssertTrue(gate.cancelPending(owner: ownerID))
        XCTAssertNil(gate.pending)
        XCTAssertEqual(dismissed, 1)
        answers[0](.open(alwaysAllow: false))
        XCTAssertEqual(opened, [], "a late answer after cancel opens nothing")
        clock += BrowserExternalOpenGate.cooldown + 0.1
        XCTAssertEqual(gate.request(vnc, origin: page, userClick: false, host: host), .prompted)
    }

    func testMailtoOpensWithoutAsking() {
        let gate = makeGate()
        let mail = URL(string: "mailto:ops@example.com")!
        XCTAssertEqual(gate.request(mail, origin: page, userClick: false, host: host), .openedDirect)
        XCTAssertEqual(opened, [mail])
        XCTAssertEqual(presented.count, 0)
    }

    func testSchemeWithNoHandlerShowsNoticeNotPrompt() {
        handler = nil
        let gate = makeGate()
        let custom = URL(string: "c11-nonexistent-scheme://x")!
        XCTAssertEqual(gate.request(custom, origin: page, userClick: true, host: host), .noHandler)
        XCTAssertEqual(presented.count, 0)
        XCTAssertEqual(opened, [])
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("c11-nonexistent-scheme:"))
    }

    func testHiddenPageIsNotPrompted() {
        visible = false
        let gate = makeGate()
        XCTAssertEqual(gate.request(vnc, origin: page, userClick: true, host: host), .droppedHidden)
        XCTAssertEqual(presented.count, 0)
        XCTAssertEqual(opened, [])
        XCTAssertNil(gate.pending)
    }

    func testWebSchemesAreNotGated() {
        let gate = makeGate()
        for raw in ["https://example.com", "http://localhost:3000", "file:///tmp/x.html", "about:blank",
                    "data:text/plain,hi", "blob:https://example.com/1"] {
            XCTAssertEqual(gate.request(URL(string: raw)!, origin: page, userClick: true, host: host), .notExternal, raw)
        }
        XCTAssertEqual(opened, [])
        XCTAssertEqual(presented.count, 0)
    }

    func testOriginWithoutHostNeverPersistsAlwaysAllow() {
        let gate = makeGate()
        let local = BrowserExternalOpenOrigin(pageURL: URL(string: "file:///tmp/page.html"))
        XCTAssertNil(local.allowKey)
        gate.request(vnc, origin: local, userClick: true, host: host)
        answers[0](.open(alwaysAllow: true))
        XCTAssertNil(defaults.string(forKey: BrowserExternalSchemeSettings.allowlistKey))
        XCTAssertFalse(browserExternalOpenAlert(for: presented[0]).showsSuppressionButton,
                       "a file page offers no always-allow choice")
    }

    func testOriginKeysKeepNonDefaultPorts() {
        XCTAssertEqual(BrowserExternalOpenOrigin(scheme: "HTTPS", host: "Example.com", port: 443).allowKey, "https://example.com")
        XCTAssertEqual(BrowserExternalOpenOrigin(scheme: "http", host: "localhost", port: 3000).allowKey, "http://localhost:3000")
        XCTAssertEqual(BrowserExternalSchemeSettings.entries(rawValue: "https://zoom.us zoommtg:\n garbage \nhttps://zoom.us ZOOMMTG"),
                       ["https://zoom.us zoommtg"])
    }

    func testPromptNamesOriginAndAppAndReturnCannotConsent() {
        let prompt = BrowserExternalOpenGate.Prompt(url: vnc, scheme: "vnc", origin: page, appName: "Screen Sharing")
        let alert = browserExternalOpenAlert(for: prompt)
        XCTAssertTrue(alert.messageText.contains("Screen Sharing"))
        XCTAssertTrue(alert.informativeText.contains("example.com"))
        XCTAssertTrue(alert.informativeText.contains("vnc://c11-fixture.invalid"))
        XCTAssertEqual(alert.buttons.map(\.title), ["Open", "Cancel"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
        XCTAssertTrue(alert.showsSuppressionButton)
    }

    // MARK: - Real web view

    /// A page's own `location = "smb://…"` reaches the gate, shows one prompt,
    /// and never reaches the system opener without consent.
    func testPageSMBNavigationInRealWebViewDoesNotReachSystemOpenWithoutConsent() async {
        var systemOpened: [URL] = []
        let saved = BrowserExternalOpenGate.systemOpen
        BrowserExternalOpenGate.systemOpen = { systemOpened.append($0); return true }
        defer { BrowserExternalOpenGate.systemOpen = saved }

        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        panel.webView.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(panel.webView)
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.close()
        }

        panel.webView.loadHTMLString(
            "<html><body><script>location.href = 'smb://c11-fixture.invalid/share';</script></body></html>",
            baseURL: URL(string: "https://c11-fixture.example/")
        )
        let asked = await waitForC11HostCondition(timeout: 10) { panel.externalOpenGate.pending != nil || !systemOpened.isEmpty }
        XCTAssertTrue(asked, "the page's smb: navigation never reached the gate")
        XCTAssertEqual(systemOpened, [], "smb: reached NSWorkspace without consent")
        XCTAssertEqual(panel.externalOpenGate.pending?.url.scheme, "smb")
        XCTAssertEqual(panel.externalOpenGate.pending?.origin.allowKey, "https://c11-fixture.example")

        // Cancel through the real sheet opens nothing.
        if let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        _ = await waitForC11HostCondition(timeout: 2) { panel.externalOpenGate.pending == nil }
        XCTAssertNil(panel.externalOpenGate.pending)
        XCTAssertEqual(systemOpened, [])
    }

    /// Agent and omnibar navigation name the URL themselves: unchanged.
    func testAgentNavigateToAppLinkStillOpensWithoutPrompt() {
        var systemOpened: [URL] = []
        let saved = BrowserExternalOpenGate.systemOpen
        BrowserExternalOpenGate.systemOpen = { systemOpened.append($0); return true }
        defer { BrowserExternalOpenGate.systemOpen = saved }

        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        XCTAssertEqual(panel.navigate(to: vnc), .proceeded)
        XCTAssertEqual(systemOpened, [vnc])
        XCTAssertNil(panel.externalOpenGate.pending)
    }

    func testPopupWithoutControllerOpensNothingForAppLinks() {
        var systemOpened: [URL] = []
        let saved = BrowserExternalOpenGate.systemOpen
        BrowserExternalOpenGate.systemOpen = { systemOpened.append($0); return true }
        defer { BrowserExternalOpenGate.systemOpen = saved }

        let delegate = PopupNavigationDelegate()
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var decisions: [WKNavigationActionPolicy] = []
        delegate.decidePolicy(for: smb, isMainFrame: true, in: webView) { decisions.append($0) }
        XCTAssertEqual(decisions, [.cancel])
        XCTAssertEqual(systemOpened, [])
    }

    // MARK: - Close and keyboard (Fable B1, notes 2 and 3)

    private func visibleWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    /// A popup closed while its prompt is up leaves the opener's gate usable.
    func testClosingPopupWithPromptUpClearsOpenerGate() async {
        var systemOpened: [URL] = []
        let saved = BrowserExternalOpenGate.systemOpen
        BrowserExternalOpenGate.systemOpen = { systemOpened.append($0); return true }
        defer { BrowserExternalOpenGate.systemOpen = saved }

        let opener = BrowserPanel(workspaceId: UUID())
        defer { opener.close() }
        let popup = BrowserPopupWindowController(
            configuration: WKWebViewConfiguration(), windowFeatures: WKWindowFeatures(), openerPanel: opener)
        let popupWindow = popup.webView.window
        _ = await waitForC11HostCondition(timeout: 5) { popup.webView.window?.isVisible == true }
        XCTAssertEqual(popup.requestExternalOpen(vnc, origin: page, userClick: false), .prompted)
        XCTAssertNotNil(opener.externalOpenGate.pending)
        XCTAssertNotNil(popupWindow?.attachedSheet, "the prompt is a sheet on the popup")

        popup.closePopup()
        _ = await waitForC11HostCondition(timeout: 3) { opener.externalOpenGate.pending == nil }
        XCTAssertNil(opener.externalOpenGate.pending, "closing the popup wedged the opener's gate")
        XCTAssertEqual(systemOpened, [])

        // After the cooldown, the opener can ask again.
        try? await Task.sleep(nanoseconds: UInt64((BrowserExternalOpenGate.cooldown + 0.2) * 1_000_000_000))
        XCTAssertEqual(opener.externalOpenGate.request(vnc, origin: page, userClick: false, host: host), .prompted)
    }

    /// Closing a panel takes its prompt off the main window.
    func testClosingPanelWithPromptUpRemovesTheSheet() async {
        let panel = BrowserPanel(workspaceId: UUID())
        let window = visibleWindow()
        panel.webView.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(panel.webView)
        defer { window.orderOut(nil); window.close() }

        XCTAssertEqual(panel.requestExternalOpen(vnc, origin: page, userClick: false, from: panel.webView), .prompted)
        _ = await waitForC11HostCondition(timeout: 3) { window.attachedSheet != nil }
        XCTAssertNotNil(window.attachedSheet)
        panel.close()
        _ = await waitForC11HostCondition(timeout: 3) { window.attachedSheet == nil }
        XCTAssertNil(window.attachedSheet, "the prompt outlived its panel")
        XCTAssertNil(panel.externalOpenGate.pending)
    }

    /// Return and Escape both cancel; neither can consent.
    func testReturnAndEscapeBothCancelThePrompt() async {
        for (characters, keyCode) in [("\r", UInt16(36)), ("\u{1b}", UInt16(53))] {
            let window = visibleWindow()
            let prompt = BrowserExternalOpenGate.Prompt(url: vnc, scheme: "vnc", origin: page, appName: "Screen Sharing")
            let alert = browserExternalOpenAlert(for: prompt)
            var response: NSApplication.ModalResponse?
            alert.beginSheetModal(for: window) { response = $0 }
            _ = await waitForC11HostCondition(timeout: 3) { window.attachedSheet != nil }
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: alert.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            // The same order NSApplication uses: key equivalents, then the key event.
            if !alert.window.performKeyEquivalent(with: event) {
                alert.window.sendEvent(event)
            }
            _ = await waitForC11HostCondition(timeout: 2) { response != nil }
            XCTAssertEqual(response, .alertSecondButtonReturn, "key code \(keyCode) must cancel")
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.close()
        }
    }

    // MARK: - Subframes and parked panels (Grok G1, G2)

    /// A modifier click on an app link inside an iframe is attributed to the
    /// iframe, never to the top page that embeds it.
    func testIframeModifierClickNamesTheIframeNotTheTopPage() async {
        var systemOpened: [URL] = []
        let saved = BrowserExternalOpenGate.systemOpen
        BrowserExternalOpenGate.systemOpen = { systemOpened.append($0); return true }
        defer { BrowserExternalOpenGate.systemOpen = saved }

        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let window = visibleWindow()
        panel.webView.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(panel.webView)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.close()
        }
        let frameHTML = "<a id=l href='vnc://c11-fixture.invalid'>x</a><script>"
            + "document.getElementById('l').dispatchEvent(new MouseEvent('click',"
            + "{metaKey:true,bubbles:true,cancelable:true}));</script>"
        let encoded = frameHTML.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        panel.webView.loadHTMLString(
            "<html><body><iframe src=\"data:text/html,\(encoded)\"></iframe></body></html>",
            baseURL: URL(string: "https://bank.example/")
        )
        let asked = await waitForC11HostCondition(timeout: 10) { panel.externalOpenGate.pending != nil }
        XCTAssertTrue(asked, "the iframe's app link never reached the gate")
        XCTAssertNotEqual(panel.externalOpenGate.pending?.origin.allowKey, "https://bank.example",
                          "the prompt named the top page for an iframe's request")
        XCTAssertEqual(systemOpened, [])
    }

    func testPopupSubframeAppLinkIsCancelledNotAllowed() {
        var systemOpened: [URL] = []
        let saved = BrowserExternalOpenGate.systemOpen
        BrowserExternalOpenGate.systemOpen = { systemOpened.append($0); return true }
        defer { BrowserExternalOpenGate.systemOpen = saved }
        let delegate = PopupNavigationDelegate()
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var decisions: [WKNavigationActionPolicy] = []
        delegate.decidePolicy(for: smb, isMainFrame: false, in: webView) { decisions.append($0) }
        XCTAssertEqual(decisions, [.cancel])
        XCTAssertEqual(systemOpened, [])
    }

    /// A keep-live panel parked off its host for a hidden workspace is not
    /// hidden, but it is not on screen either: no sheet.
    func testWebViewParkedOutsideItsWindowIsNotPrompted() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let window = visibleWindow()
        defer { window.orderOut(nil); window.close() }
        let bounds = window.contentView?.bounds ?? .zero
        panel.webView.frame = bounds.offsetBy(dx: -(bounds.width + 64), dy: 0)
        window.contentView?.addSubview(panel.webView)
        XCTAssertFalse(panel.webView.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(panel.requestExternalOpen(vnc, origin: page, userClick: false, from: panel.webView), .droppedHidden)
        XCTAssertNil(window.attachedSheet)

        panel.webView.frame = bounds
        XCTAssertEqual(panel.requestExternalOpen(vnc, origin: page, userClick: false, from: panel.webView), .prompted)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
    }
}