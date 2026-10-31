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
    }

    func testMalformedAndDecoratedLinksAreRefused() {
        for link in [
            "c11://panel/", "c11://panel/not-a-uuid", "c11://panel/panel:10",
            "c11://panel/\(id)/extra", "c11://panel/\(id)/", "c11://panel//\(id)",
            "c11://panel/\(id)?", "c11://panel/\(id)?a=1", "c11://panel/\(id)#",
            "c11://panel/\(id)#fragment", "c11://user@panel/\(id)", "c11://panel:80/\(id)",
            "c11://window/\(id)", "https://panel/\(id)", "c11:panel/\(id)",
            "c11://panel/%30\(id.uuidString.dropFirst())", "c11://panel/%2F\(id)",
            " c11://panel/\(id)", "c11://panel/\(id)\n"
        ] {
            XCTAssertNil(PanelLinkTarget(link), link)
        }
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
