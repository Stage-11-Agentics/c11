import XCTest
import CoreGraphics

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class PanelLinkPolicyTests: XCTestCase {
    private let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

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
