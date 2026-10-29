import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-507. Omnibar search suggestions run on one session per browser profile
/// with no cookies, so a search engine's cookie cannot link one profile's
/// typing to another's or land in the app-wide jar.
final class BrowserSearchSuggestionSessionTests: XCTestCase {
    private static let engineCookie = "c11_507_engine"

    func testSuggestionResponseCannotSetACookieForLaterRequests() async throws {
        let server = try LoopbackHTTPListener { path in
            path == "/sets-cookie" ? ["Set-Cookie: \(Self.engineCookie)=linked; Path=/; Max-Age=3600"] : []
        }
        defer {
            server.stop()
            for cookie in HTTPCookieStorage.shared.cookies ?? []
            where cookie.name == Self.engineCookie || cookie.domain == "127.0.0.1" {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        let base = "http://127.0.0.1:\(server.port)"
        let session = await BrowserSearchSuggestionService().session(forProfile: UUID())

        _ = try await session.data(from: URL(string: "\(base)/sets-cookie")!)
        _ = try await session.data(from: URL(string: "\(base)/next")!)

        let next = try XCTUnwrap(server.requests.last { $0.path == "/next" })
        XCTAssertNil(next.cookie, "A later suggestion request sent the cookie an earlier response set")
        XCTAssertFalse(
            (HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == Self.engineCookie },
            "A suggestion response stored its cookie in the app-wide jar"
        )
    }

    func testEachProfileHasItsOwnSession() async {
        let service = BrowserSearchSuggestionService()
        let profileA = UUID()
        let first = await service.session(forProfile: profileA)
        let again = await service.session(forProfile: profileA)
        let other = await service.session(forProfile: UUID())

        XCTAssertTrue(first === again)
        XCTAssertFalse(first === other)
        XCTAssertFalse(first.configuration.urlCache === other.configuration.urlCache)
        XCTAssertEqual(first.configuration.urlCache?.diskCapacity, 0, "Typed queries reached a disk cache")
    }
}
