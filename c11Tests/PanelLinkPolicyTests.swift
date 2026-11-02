import XCTest
import CoreGraphics
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class PanelLinkPolicyTests: XCTestCase {
    private let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

    @MainActor
    func testExternalGetURLConsumesC11BeforeSceneFallback() {
        let inputs = ["c11://panel/\(id)", " C11://workspace/\(id) ", "c11:invalid",
                      "c11://%", "c11://panel/\(id)?run=x", "c11:" + String(repeating: "x", count: 10_000)]
        var consumed: [String] = []
        var forwarded: [URL] = []
        for input in inputs {
            AppDelegate.routeExternalGetURL(input, panelLink: { consumed.append($0) }, otherURL: { forwarded.append($0) })
        }
        XCTAssertEqual(consumed, inputs)
        XCTAssertTrue(forwarded.isEmpty)
        // An oversized whitespace prefix cannot hide c11 from classification
        // and reach the scene fallback.
        AppDelegate.routeExternalGetURL(String(repeating: " ", count: 1000) + "c11:invalid",
            panelLink: { consumed.append($0) }, otherURL: { forwarded.append($0) })
        XCTAssertTrue(forwarded.isEmpty)
    }

    @MainActor
    func testExternalGetURLPreservesOtherURLRouteAndDropsMissingPayload() throws {
        let inputs = ["http://localhost:1234/a", "https://example.com/c11:notes", "file:///tmp/example",
                      "https://example.com/" + String(repeating: "x", count: 2000)]
        var forwarded: [URL] = []
        for input in inputs {
            AppDelegate.routeExternalGetURL(input, panelLink: { XCTFail("Unexpected c11 consumption: \($0)") },
                otherURL: { forwarded.append($0) })
        }
        XCTAssertEqual(forwarded, try inputs.map { try XCTUnwrap(URL(string: $0)) })
        let missing: [String?] = [nil, "", String(repeating: " ", count: 1000)]
        for input in missing {
            AppDelegate.routeExternalGetURL(input, panelLink: { _ in XCTFail("Missing payload cannot navigate") },
                otherURL: { _ in XCTFail("Missing payload cannot create a scene") })
        }
    }

    func testTerminalConsumesEveryInternalSchemeBeforeExternalResolution() {
        for link in ["c11://panel/\(id)", "C11:panel/\(id)", "c11:notes", "c11://%", "c11://panel/not-a-uuid", " c11://workspace/\(id) "] {
            XCTAssertTrue(PanelLinkTarget.usesScheme(link), link)
            XCTAssertNil(resolveTerminalOpenURLTarget(link), link)
        }
        XCTAssertFalse(PanelLinkTarget.usesScheme("https://example.com/c11:notes"))
        XCTAssertFalse(PanelLinkTarget.usesScheme("c110://panel/\(id)"))
        XCTAssertEqual(resolveTerminalOpenURLTarget("mailto:test@example.com"), .external(URL(string: "mailto:test@example.com")!))
        XCTAssertEqual(resolveTerminalOpenURLTarget("https://example.com"), .embeddedBrowser(URL(string: "https://example.com")!))
    }

    func testTerminalRequiresNativeCommandClickAndNeverSocketAuthority() {
        let valid = TerminalPanelLinkPolicy(isNativeCommandClick: true, isSocketCommand: false, isKeyWindow: true, isVisible: true)
        XCTAssertNil(valid.refusalReason)
        var value = valid
        value.isNativeCommandClick = false
        XCTAssertEqual(value.refusalReason, "missing_native_input")
        value = valid
        value.isSocketCommand = true
        XCTAssertEqual(value.refusalReason, "socket_command")
        value = valid
        value.isKeyWindow = false
        XCTAssertEqual(value.refusalReason, "window_not_key")
        value = valid
        value.isVisible = false
        XCTAssertEqual(value.refusalReason, "view_hidden")
    }

    func testExactUUIDLinksAreCaseInsensitive() {
        XCTAssertEqual(PanelLinkTarget("c11://panel/\(id.uuidString)"), .panel(id))
        XCTAssertEqual(PanelLinkTarget("C11://WORKSPACE/\(id.uuidString.lowercased())"), .workspace(id))
        XCTAssertEqual(PanelLinkTarget(" \tc11://panel/\(id)\n "), .panel(id))
    }

    func testMalformedAndDecoratedLinksAreRefused() {
        for link in [
            "c11://panel/", "c11://panel/not-a-uuid", "c11://panel/panel:10",
            "c11://panel/\(id)/extra", "c11://panel/\(id)/", "c11://panel//\(id)",
            "c11://panel/\(id)?", "c11://panel/\(id)?a=1", "c11://panel/\(id)#",
            "c11://panel/\(id)#fragment", "c11://user@panel/\(id)", "c11://panel:80/\(id)",
            "c11://window/\(id)", "https://panel/\(id)", "c11:panel/\(id)",
            "c11://panel/%30\(id.uuidString.dropFirst())", "c11://panel/%2F\(id)"
        ] {
            XCTAssertNil(PanelLinkTarget(link), link)
        }
    }

    func testOnlyLinkPrefixInterceptsSearchInputWhileAllSchemeURLsStayBlocked() {
        XCTAssertTrue(PanelLinkTarget.isLink(" \nC11://panel/\(id) "))
        XCTAssertFalse(PanelLinkTarget.isLink("c11: notes"))
        XCTAssertFalse(PanelLinkTarget.isLink("c11:notes"))
        XCTAssertNil(resolveBrowserNavigableURL("c11: notes"))
        XCTAssertTrue(PanelLinkTarget.usesScheme(URL(string: "c11:notes")!))
        XCTAssertTrue(PanelLinkTarget.usesScheme(URL(string: "c11://panel/\(id)")!))
        XCTAssertFalse(PanelLinkTarget.usesScheme(URL(string: "https://localhost")!))
    }

    func testActivationRefusalReportsFirstFailedCondition() {
        let intent = PanelLinkNativeIntent(kind: .pointer, uptime: 10, point: CGPoint(x: 100, y: 200))
        let valid = PanelLinkActivationPolicy(trusted: true, supported: true, isMainFrame: true,
                                             isSocketCommand: false, isKeyWindow: true, isVisible: true, sameDocument: true)
        func reason(_ policy: PanelLinkActivationPolicy) -> String? {
            policy.refusalReason(kind: .pointer, intent: intent, point: intent.point, now: 10.2)
        }
        XCTAssertNil(reason(valid))
        for (key, value, expected) in [
            (\PanelLinkActivationPolicy.trusted, false, "untrusted_event"),
            (\PanelLinkActivationPolicy.supported, false, "unsupported_activation"),
            (\PanelLinkActivationPolicy.isMainFrame, false, "subframe"),
            (\PanelLinkActivationPolicy.isSocketCommand, true, "socket_command"),
            (\PanelLinkActivationPolicy.isKeyWindow, false, "window_not_key"),
            (\PanelLinkActivationPolicy.isVisible, false, "view_hidden"),
            (\PanelLinkActivationPolicy.sameDocument, false, "document_changed")
        ] {
            var policy = valid
            policy[keyPath: key] = value
            XCTAssertEqual(reason(policy), expected)
        }
        var overlapping = valid
        overlapping.trusted = false
        overlapping.isMainFrame = false
        XCTAssertEqual(reason(overlapping), "untrusted_event")
        XCTAssertEqual(valid.refusalReason(kind: nil, intent: intent, point: intent.point, now: 10.2), "invalid_activation_kind")
        XCTAssertEqual(valid.refusalReason(kind: .pointer, intent: nil, point: intent.point, now: 10.2), "missing_native_input")
        XCTAssertEqual(valid.refusalReason(kind: .keyboard, intent: intent, point: nil, now: 10.2), "input_kind_mismatch")
        XCTAssertEqual(valid.refusalReason(kind: .pointer, intent: intent, point: intent.point, now: 12), "input_expired")
        XCTAssertEqual(valid.refusalReason(kind: .pointer, intent: intent, point: nil, now: 10.2), "input_point_missing")
        XCTAssertEqual(valid.refusalReason(kind: .pointer, intent: intent, point: .zero, now: 10.2), "input_point_mismatch")
    }

    func testOnlyMainFrameLocalOriginsAreAllowed() {
        XCTAssertTrue(PanelLinkOriginPolicy.allows(scheme: "file", host: "", isMainFrame: true))
        for scheme in ["http", "https"] {
            for host in ["localhost", "LOCALHOST", "127.0.0.1", "::1", "[::1]"] {
                XCTAssertTrue(PanelLinkOriginPolicy.allows(scheme: scheme, host: host, isMainFrame: true))
                XCTAssertFalse(PanelLinkOriginPolicy.allows(scheme: scheme, host: host, isMainFrame: false))
            }
        }
        for host in ["", "127.0.0.2", "localhost.example.com", "example.com", "192.168.64.2", "localhost."] {
            XCTAssertFalse(PanelLinkOriginPolicy.allows(scheme: "http", host: host, isMainFrame: true))
        }
        for scheme in ["data", "about", "javascript", "c11md", "c11", "ftp"] {
            XCTAssertFalse(PanelLinkOriginPolicy.allows(scheme: scheme, host: "localhost", isMainFrame: true))
        }
        XCTAssertFalse(PanelLinkOriginPolicy.allows(scheme: "file", host: "", isMainFrame: false))
    }

    func testNativeIntentMustMatchKindLocationAndLifetime() {
        let pointer = PanelLinkNativeIntent(kind: .pointer, uptime: 10, point: CGPoint(x: 100, y: 200))
        XCTAssertTrue(pointer.matches(kind: .pointer, point: CGPoint(x: 100, y: 200), now: 10.2))
        XCTAssertFalse(pointer.matches(kind: .pointer, point: CGPoint(x: 120, y: 200), now: 10.2))
        XCTAssertFalse(pointer.matches(kind: .pointer, point: nil, now: 10.2))
        XCTAssertFalse(pointer.matches(kind: .keyboard, point: nil, now: 10.2))
        XCTAssertFalse(pointer.matches(kind: .pointer, point: CGPoint(x: 100, y: 200), now: 13))
        XCTAssertFalse(pointer.matches(kind: .pointer, point: CGPoint(x: 100, y: 200), now: 9))
        let keyboard = PanelLinkNativeIntent(kind: .keyboard, uptime: 10, point: nil)
        XCTAssertTrue(keyboard.matches(kind: .keyboard, point: nil, now: 10.2))
        XCTAssertFalse(keyboard.matches(kind: .pointer, point: CGPoint(x: 0, y: 0), now: 10.2))
    }
}

@MainActor
final class ExternalPanelLinkRequestTests: XCTestCase {
    private let panelID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
    private let workspaceID = UUID(uuidString: "11234567-89AB-CDEF-0123-456789ABCDEF")!

    private var destination: ExternalPanelLinkDestination {
        ExternalPanelLinkDestination(target: .panel(panelID), workspaceID: workspaceID,
                                     workspaceTitle: "Workspace A", panelTitle: "Panel A")
    }

    func testRequestDoesNothingUntilConfirmAndCanBeConsumedOnlyOnce() throws {
        let expected = destination
        var opened: [PanelLinkTarget] = []
        var clock: TimeInterval = 100
        let request = ExternalPanelLinkRequest(now: { clock }, armingDelay: 0.75, resolve: { _ in expected },
                                              open: { opened.append($0); return true })
        let prompt = try XCTUnwrap(request.receive(expected.url))
        XCTAssertEqual(prompt.destination, expected)
        XCTAssertTrue(opened.isEmpty)
        clock = 101
        XCTAssertEqual(request.finish(id: prompt.id, confirm: true), "opened")
        XCTAssertEqual(opened, [expected.target])
        XCTAssertEqual(request.finish(id: prompt.id, confirm: true), "stale_confirmation")
        XCTAssertEqual(opened.count, 1)
    }

    func testBurstCannotQueueOrReplacePromptAndCooldownStartsAtDismissal() throws {
        let expected = destination
        var clock: TimeInterval = 100
        var resolutions = 0
        var opens = 0
        let request = ExternalPanelLinkRequest(now: { clock }, armingDelay: 0.75, resolve: { _ in resolutions += 1; return expected },
                                              open: { _ in opens += 1; return true })
        let first = try XCTUnwrap(request.receive(expected.url))
        for _ in 0..<50 { XCTAssertNil(request.receive("c11://workspace/\(UUID())")) }
        XCTAssertEqual(request.pending?.id, first.id)
        XCTAssertEqual(request.pending?.destination, expected)
        XCTAssertEqual(resolutions, 1)
        clock = 110
        XCTAssertEqual(request.finish(id: first.id, confirm: false), "cancelled")
        XCTAssertNil(request.pending)
        clock = 111.99
        XCTAssertNil(request.receive(expected.url))
        clock = 112
        XCTAssertNotNil(request.receive(expected.url))
        XCTAssertEqual(opens, 0)
    }

    func testMalformedAndOversizedOutsideInputsNeverResolveOrOpen() throws {
        let url = destination.url
        for href in ["c11:notes", "c11://panel/panel:1", "c11://panel/not-a-uuid",
                     url + "?", url + "#", url + "?command=touch%20/tmp/no",
                     url + "/extra", url + "/", "c11://user@panel/\(panelID)",
                     "c11://panel:10/\(panelID)", "c11://panel/%30\(panelID.uuidString.dropFirst())",
                     "c11://panel/" + String(repeating: "a", count: 100_000),
                     String(repeating: " ", count: 100_000) + url] {
            var resolved = false
            var opened = false
            let request = ExternalPanelLinkRequest(now: { 100 }, armingDelay: 0.75, resolve: { _ in resolved = true; return self.destination },
                                                  open: { _ in opened = true; return true })
            let prompt = try XCTUnwrap(request.receive(href))
            XCTAssertNil(prompt.destination)
            XCTAssertEqual(prompt.notice?.text, PanelLinkNotice.invalid.text)
            XCTAssertEqual(request.finish(id: prompt.id, confirm: true), "unavailable")
            XCTAssertFalse(resolved, href.prefix(100).description)
            XCTAssertFalse(opened)
        }
    }

    func testUnknownClosedOrMovedTargetNeverUsesFallback() throws {
        let expected = destination
        var live: ExternalPanelLinkDestination? = nil
        var opens = 0
        var clock: TimeInterval = 100
        let request = ExternalPanelLinkRequest(now: { clock }, armingDelay: 0.75, resolve: { _ in live },
                                              open: { _ in opens += 1; return true })
        let unknown = try XCTUnwrap(request.receive(expected.url))
        XCTAssertEqual(unknown.notice?.text, PanelLinkNotice.unavailable.text)
        request.finish(id: unknown.id, confirm: false)
        for replacement in [nil,
                            ExternalPanelLinkDestination(target: expected.target, workspaceID: UUID(),
                                workspaceTitle: "Workspace A", panelTitle: "Panel A")] {
            clock += 3
            live = expected
            let prompt = try XCTUnwrap(request.receive(expected.url))
            live = replacement
            clock += 1
            XCTAssertEqual(request.finish(id: prompt.id, confirm: true), replacement == nil ? "unavailable" : "destination_changed")
        }
        XCTAssertEqual(opens, 0)
    }

    func testExpiredOrSocketConfirmationCannotNavigate() throws {
        let expected = destination
        var clock: TimeInterval = 100
        var opens = 0
        let request = ExternalPanelLinkRequest(now: { clock }, armingDelay: 0.75, resolve: { _ in expected },
                                              open: { _ in opens += 1; return true })
        let prompt = try XCTUnwrap(request.receive(expected.url))
        clock = 160
        XCTAssertEqual(request.finish(id: prompt.id, confirm: true), "expired")
        clock = 162
        let second = try XCTUnwrap(request.receive(expected.url))
        clock = 163
        XCTAssertEqual(request.finish(id: second.id, confirm: true, isSocketCommand: true), "socket_command")
        XCTAssertEqual(opens, 0)
    }

    func testStaleTimerCannotDismissNewPromptAndFailureNoticeKeepsAdmission() throws {
        let expected = destination
        var clock: TimeInterval = 100
        let request = ExternalPanelLinkRequest(now: { clock }, armingDelay: 0.75, resolve: { _ in expected }, open: { _ in false })
        let first = try XCTUnwrap(request.receive(expected.url))
        clock = 101
        XCTAssertEqual(request.finish(id: first.id, confirm: true), "unavailable")
        let notice = request.showNotice(.unavailable)
        XCTAssertNil(request.receive(expected.url))
        XCTAssertEqual(request.finish(id: first.id, confirm: false), "stale_confirmation")
        XCTAssertEqual(request.pending?.id, notice.id)
        request.finish(id: notice.id, confirm: false)
        clock = 103
        let second = try XCTUnwrap(request.receive(expected.url))
        XCTAssertEqual(request.finish(id: notice.id, confirm: false), "stale_confirmation")
        XCTAssertEqual(request.pending?.id, second.id)
    }

    func testMixedURLEventIsExclusiveEvenWhenPendingInvalidExpiredOrRateLimited() throws {
        let expected = destination
        let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
        var clock: TimeInterval = 100
        var folders: [[URL]] = []
        var opens = 0
        let request = ExternalPanelLinkRequest(now: { clock }, armingDelay: 0.75, resolve: { _ in expected },
                                              open: { _ in opens += 1; return true })
        func route(_ urls: [URL]) {
            AppDelegate.routeExternalOpenURLs(urls, panelLink: { request.receive($0.absoluteString) },
                                               directories: { folders.append($0) })
        }
        for href in [expected.url, "c11:invalid", "c11://panel/panel:1"] {
            let url = try XCTUnwrap(URL(string: href))
            for urls in [[url, folder], [folder, url]] {
                route(urls)
                route(urls) // Already pending, still no folder action.
                clock += 61
                route(urls) // Expired but not dismissed, still no folder action.
                let pending = try XCTUnwrap(request.pending)
                request.finish(id: pending.id, confirm: false)
                route(urls) // In cooldown, still no folder action.
                clock += 3
            }
        }
        XCTAssertTrue(folders.isEmpty)
        XCTAssertEqual(opens, 0)
        route([folder])
        XCTAssertEqual(folders, [[folder]])
    }

    func testRequestArmingIgnoresEarlyConfirmAndAllowsOrdinaryTitleChanges() throws {
        let expected = destination
        var clock: TimeInterval = 100
        var live = expected
        var opens = 0
        let request = ExternalPanelLinkRequest(now: { clock }, armingDelay: 0.75, resolve: { _ in live },
                                              open: { _ in opens += 1; return true })
        let prompt = try XCTUnwrap(request.receive(expected.url))
        clock = 100.2
        XCTAssertEqual(request.finish(id: prompt.id, confirm: true), "not_armed")
        XCTAssertEqual(request.pending?.id, prompt.id)
        XCTAssertEqual(opens, 0)
        live = ExternalPanelLinkDestination(target: expected.target, workspaceID: expected.workspaceID,
                                            workspaceTitle: "Renamed workspace", panelTitle: "Live build title changed")
        clock = 101
        XCTAssertEqual(request.finish(id: prompt.id, confirm: true), "opened")
        XCTAssertEqual(opens, 1)
    }

    func testColdStartupHoldsOneBoundedURLAndPreservesOriginalDeadline() throws {
        let expected = destination
        var hold = ExternalPanelLinkStartupHold()
        let first = try XCTUnwrap(hold.capture(expected.url, now: 100))
        XCTAssertNil(hold.capture("c11:other", now: 101))
        let delivered = try XCTUnwrap(hold.take(now: 159))
        XCTAssertEqual(delivered.href, expected.url)
        XCTAssertEqual(delivered.expiresAt, 160)
        XCTAssertNil(hold.take(now: 159))
        var clock: TimeInterval = 159
        let request = ExternalPanelLinkRequest(now: { clock }, armingDelay: 0.75, resolve: { _ in expected }, open: { _ in XCTFail("expired"); return true })
        let prompt = try XCTUnwrap(request.receive(delivered.href, expiresAt: delivered.expiresAt))
        clock = 160
        XCTAssertEqual(request.finish(id: prompt.id, confirm: true), "expired")
        let second = try XCTUnwrap(hold.capture(String(repeating: "x", count: 100_000), now: 200))
        XCTAssertEqual(second.href, "c11:invalid")
        hold.expire(id: first.id, now: 260)
        XCTAssertEqual(hold.pending?.id, second.id)
        hold.expire(id: second.id, now: 259)
        XCTAssertNotNil(hold.pending)
        hold.expire(id: second.id, now: 260)
        XCTAssertNil(hold.pending)
        _ = hold.capture(expected.url, now: 300)
        XCTAssertNil(hold.take(now: 360))
        XCTAssertNil(hold.pending)
    }

    func testWorkspaceLinkConfirmsExactWorkspaceWithoutInventingPanel() throws {
        let expected = ExternalPanelLinkDestination(target: .workspace(workspaceID), workspaceID: workspaceID,
                                                   workspaceTitle: "Workspace B", panelTitle: nil)
        var opened: PanelLinkTarget?
        var clock: TimeInterval = 100
        let request = ExternalPanelLinkRequest(now: { clock }, armingDelay: 0.75, resolve: { target in
            XCTAssertEqual(target, .workspace(self.workspaceID)); return expected
        }, open: { opened = $0; return true })
        let prompt = try XCTUnwrap(request.receive(expected.url))
        XCTAssertNil(prompt.destination?.panelTitle)
        XCTAssertNil(opened)
        clock = 101
        XCTAssertEqual(request.finish(id: prompt.id, confirm: true), "opened")
        XCTAssertEqual(opened, .workspace(workspaceID))
    }
}

final class ExternalPanelLinkGestureTests: XCTestCase {
    func testLongerSystemDoubleClickIntervalSetsArmingDeadline() {
        var gate = ExternalPanelLinkGesture(presentedAt: 100, doubleClickInterval: 1.0, pointerInside: false)
        XCTAssertFalse(gate.isArmed(at: 100.999))
        XCTAssertFalse(gate.begin(at: 100.999, plain: true, clickCount: 1, inside: true))
        XCTAssertTrue(gate.isArmed(at: 101))
        XCTAssertTrue(gate.begin(at: 101, plain: true, clickCount: 1, inside: true))
        XCTAssertTrue(gate.end(at: 101.1, plain: true, clickCount: 1, inside: true))
    }

    func testDelayFreshPlainClickAndSingleClickAreRequired() {
        var gate = ExternalPanelLinkGesture(presentedAt: 100, doubleClickInterval: 0.5, pointerInside: false)
        XCTAssertFalse(gate.isArmed(at: 100.49))
        XCTAssertFalse(gate.begin(at: 100.49, plain: true, clickCount: 1, inside: true))
        XCTAssertFalse(gate.end(at: 100.6, plain: true, clickCount: 1, inside: true))
        XCTAssertTrue(gate.isArmed(at: 100.75))
        XCTAssertFalse(gate.begin(at: 100.8, plain: true, clickCount: 2, inside: true))
        XCTAssertFalse(gate.begin(at: 100.8, plain: false, clickCount: 1, inside: true))
        XCTAssertFalse(gate.begin(at: 100.8, plain: true, clickCount: 1, inside: false))
        XCTAssertTrue(gate.begin(at: 100.8, plain: true, clickCount: 1, inside: true))
        XCTAssertTrue(gate.end(at: 100.9, plain: true, clickCount: 1, inside: true))
        XCTAssertFalse(gate.end(at: 100.9, plain: true, clickCount: 1, inside: true))
    }

    func testPointerAlreadyOverButtonMustLeaveThenReenter() {
        var gate = ExternalPanelLinkGesture(presentedAt: 100, doubleClickInterval: 0.7, pointerInside: true)
        gate.pointer(inside: true)
        XCTAssertFalse(gate.isArmed(at: 101))
        XCTAssertFalse(gate.begin(at: 101, plain: true, clickCount: 1, inside: true))
        gate.pointer(inside: false)
        XCTAssertFalse(gate.isArmed(at: 101))
        gate.pointer(inside: true)
        XCTAssertTrue(gate.isArmed(at: 101))
        XCTAssertTrue(gate.begin(at: 101, plain: true, clickCount: 1, inside: true))
        XCTAssertTrue(gate.end(at: 101.1, plain: true, clickCount: 1, inside: true))
    }

    func testReleaseOutsideModifiersAndCancelledPressCannotConfirm() {
        var gate = ExternalPanelLinkGesture(presentedAt: 100, doubleClickInterval: 0.5, pointerInside: false)
        XCTAssertTrue(gate.begin(at: 101, plain: true, clickCount: 1, inside: true))
        XCTAssertFalse(gate.end(at: 101.1, plain: false, clickCount: 1, inside: true))
        XCTAssertTrue(gate.begin(at: 101.2, plain: true, clickCount: 1, inside: true))
        XCTAssertFalse(gate.end(at: 101.3, plain: true, clickCount: 1, inside: false))
        XCTAssertTrue(gate.begin(at: 101.4, plain: true, clickCount: 1, inside: true))
        XCTAssertFalse(gate.end(at: 101.3, plain: true, clickCount: 1, inside: true))
        XCTAssertTrue(gate.begin(at: 102, plain: true, clickCount: 1, inside: true))
        gate.cancelPress()
        XCTAssertFalse(gate.end(at: 102.1, plain: true, clickCount: 1, inside: true))
    }
}

@MainActor
final class ExternalPanelLinkButtonRowTests: XCTestCase {
    /// C11-562: Cancel is the rightmost button and the only Return default;
    /// Confirm sits left of it, disabled until its gesture arms.
    func testConfirmSitsLeftOfCancelAndCancelKeepsReturn() throws {
        let row = ExternalPanelLinkPresenter.makeButtonRow(requestID: UUID(), hasDestination: true, target: nil)
        let ids = row.stack.arrangedSubviews.map { $0.accessibilityIdentifier() }
        XCTAssertEqual(ids, ["c11.external-link.confirm", "c11.external-link.cancel"])
        let confirm = try XCTUnwrap(row.confirm)
        XCTAssertTrue(row.stack.arrangedSubviews.last === row.cancel)
        XCTAssertEqual(row.cancel.keyEquivalent, "\r")
        XCTAssertEqual(confirm.keyEquivalent, "")
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertTrue(row.cancel.isEnabled)
    }

    /// C11-565: Return and Escape go through the window's key gate, so no
    /// button holds Escape and no hidden twin remains in the row.
    func testNoButtonHoldsEscape() {
        for hasDestination in [true, false] {
            let row = ExternalPanelLinkPresenter.makeButtonRow(requestID: UUID(), hasDestination: hasDestination, target: nil)
            XCTAssertEqual(row.stack.subviews.filter { ($0 as? NSButton)?.keyEquivalent == "\u{1b}" }.count, 0)
            XCTAssertEqual(row.stack.subviews.count, row.stack.arrangedSubviews.count)
            for case let button as NSButton in row.stack.subviews {
                XCTAssertTrue(button.refusesFirstResponder)
            }
        }
    }

    func testNoticeShowsCancelAlone() {
        let row = ExternalPanelLinkPresenter.makeButtonRow(requestID: UUID(), hasDestination: false, target: nil)
        XCTAssertNil(row.confirm)
        XCTAssertEqual(row.stack.arrangedSubviews.map { $0.accessibilityIdentifier() }, ["c11.external-link.cancel"])
        XCTAssertEqual(row.cancel.keyEquivalent, "\r")
    }
}

final class ExternalPanelLinkKeyGateTests: XCTestCase {
    func testFreshPlainPressCancelsOnKeyUpOnly() {
        for code: UInt16 in [36, 76, 53] {
            var gate = ExternalPanelLinkKeyGate()
            gate.keyDown(keyCode: code, isRepeat: false, plain: true)
            XCTAssertTrue(gate.keyUp(keyCode: code))
            XCTAssertFalse(gate.keyUp(keyCode: code))
        }
    }

    func testHeldKeyFromBeforeThePromptDoesNothing() {
        var gate = ExternalPanelLinkKeyGate()
        gate.keyDown(keyCode: 36, isRepeat: true, plain: true)
        gate.keyDown(keyCode: 36, isRepeat: true, plain: true)
        XCTAssertFalse(gate.keyUp(keyCode: 36))
        XCTAssertFalse(gate.keyUp(keyCode: 53))
    }

    func testHoldingReturnCancelsOnceOnRelease() {
        var gate = ExternalPanelLinkKeyGate()
        gate.keyDown(keyCode: 36, isRepeat: false, plain: true)
        for _ in 0..<30 { gate.keyDown(keyCode: 36, isRepeat: true, plain: true) }
        XCTAssertTrue(gate.keyUp(keyCode: 36))
        XCTAssertFalse(gate.keyUp(keyCode: 36))
    }

    func testModifiedOtherAndInterleavedKeysDoNotCancel() {
        var gate = ExternalPanelLinkKeyGate()
        gate.keyDown(keyCode: 36, isRepeat: false, plain: false)
        XCTAssertFalse(gate.keyUp(keyCode: 36))
        for code: UInt16 in [49, 48, 0] { // Space, Tab, A
            gate.keyDown(keyCode: code, isRepeat: false, plain: true)
            XCTAssertFalse(gate.keyUp(keyCode: code))
        }
        gate.keyDown(keyCode: 53, isRepeat: false, plain: true)
        gate.keyDown(keyCode: 0, isRepeat: false, plain: true)
        XCTAssertFalse(gate.keyUp(keyCode: 53))
        XCTAssertTrue(ExternalPanelLinkKeyGate.isPlain([.shift]))
        XCTAssertFalse(ExternalPanelLinkKeyGate.isPlain([.command]))
        XCTAssertFalse(ExternalPanelLinkKeyGate.isPlain([.option]))
        XCTAssertFalse(ExternalPanelLinkKeyGate.isPlain([.control]))
    }
}

@MainActor
final class ExternalPanelLinkWindowKeyTests: XCTestCase {
    // c11LogicTests has no host app; windows need the shared application.
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func key(_ type: NSEvent.EventType, _ code: UInt16, _ chars: String,
                     repeating: Bool = false, flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: repeating, keyCode: code)!
    }

    private func makeWindow() -> ExternalPanelLinkWindow {
        let window = ExternalPanelLinkWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                             styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.takesKeyFocus = true
        return window
    }

    /// Key only for a prompt shown while another app was active; never main.
    func testPromptBecomesKeyOnlyWhenShownFromAnotherApp() {
        let window = makeWindow()
        XCTAssertTrue(window.canBecomeKey)
        window.takesKeyFocus = false
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
    }

    func testReturnAndEscapeCancelOnKeyUpThroughSendEvent() {
        for (code, chars) in [(UInt16(36), "\r"), (53, "\u{1b}"), (76, "\u{3}")] {
            let window = makeWindow()
            var cancels = 0
            window.onCancelKey = { cancels += 1 }
            window.sendEvent(key(.keyDown, code, chars, window: window))
            XCTAssertEqual(cancels, 0, "key-down alone must not cancel")
            window.sendEvent(key(.keyDown, code, chars, repeating: true, window: window))
            window.sendEvent(key(.keyUp, code, chars, window: window))
            XCTAssertEqual(cancels, 1)
            window.sendEvent(key(.keyUp, code, chars, window: window))
            XCTAssertEqual(cancels, 1)
        }
    }

    func testRepeatOrReleaseWithoutFreshPressDoesNotCancel() {
        let window = makeWindow()
        var cancels = 0
        window.onCancelKey = { cancels += 1 }
        window.sendEvent(key(.keyDown, 36, "\r", repeating: true, window: window))
        window.sendEvent(key(.keyUp, 36, "\r", window: window))
        window.sendEvent(key(.keyDown, 36, "\r", flags: [.command], window: window))
        window.sendEvent(key(.keyUp, 36, "\r", window: window))
        XCTAssertEqual(cancels, 0)
    }

    /// The default button's Return must never fire on key-down: that path would
    /// close the prompt mid-press and hand autorepeat to the window behind.
    func testKeyEquivalentsNeverReachTheDefaultButton() {
        final class Recorder: NSObject { var fired = 0; @objc func fire(_ sender: Any?) { fired += 1 } }
        let window = makeWindow()
        let recorder = Recorder()
        let button = NSButton(title: "Cancel", target: recorder, action: #selector(Recorder.fire(_:)))
        button.keyEquivalent = "\r"
        window.contentView?.addSubview(button)
        window.defaultButtonCell = button.cell as? NSButtonCell
        // Not key: the prompt claims nothing, so a terminal's key equivalents pass by.
        XCTAssertFalse(window.performKeyEquivalent(with: key(.keyDown, 36, "\r", window: window)))
        window.sendEvent(key(.keyDown, 36, "\r", window: window))
        window.sendEvent(key(.keyDown, 49, " ", window: window))
        window.sendEvent(key(.keyDown, 48, "\t", window: window))
        XCTAssertEqual(recorder.fired, 0)
    }
}

@MainActor
final class ExternalPanelLinkPresenterKeyTests: XCTestCase {
    // c11LogicTests has no host app; windows need the shared application.
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func key(_ type: NSEvent.EventType, _ code: UInt16, _ chars: String, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// C11-565 acceptance 1 and 2: Return and Escape cancel a live prompt;
    /// no key, including Return, Space and Tab after arming, confirms it.
    func testKeysCancelThePromptAndNeverConfirm() throws {
        let target = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        for (code, chars) in [(UInt16(36), "\r"), (53, "\u{1b}")] {
            var opened = 0
            let presenter = ExternalPanelLinkPresenter(
                resolve: { ExternalPanelLinkDestination(target: $0, workspaceID: target, workspaceTitle: "W", panelTitle: "P") },
                open: { _ in opened += 1; return true })
            presenter.receive("c11://panel/\(target.uuidString)")
            let window = try XCTUnwrap(presenter.presentedWindow)
            XCTAssertTrue(presenter.isPresenting)
            XCTAssertEqual(window.canBecomeKey, !NSApp.isActive)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0)) // past the arming delay
            for (other, otherChars) in [(UInt16(49), " "), (48, "\t")] {
                window.sendEvent(key(.keyDown, other, otherChars, window: window))
                window.sendEvent(key(.keyUp, other, otherChars, window: window))
            }
            XCTAssertTrue(presenter.isPresenting)
            window.sendEvent(key(.keyDown, code, chars, window: window))
            XCTAssertTrue(presenter.isPresenting, "cancel waits for key-up")
            window.sendEvent(key(.keyUp, code, chars, window: window))
            XCTAssertFalse(presenter.isPresenting)
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(opened, 0)
        }
    }
}
