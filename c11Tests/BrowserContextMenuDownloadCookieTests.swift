import XCTest
import WebKit
import Network

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-487. Download Image and Download Linked File fetch a URL the page chose,
/// so the request must carry only the cookies WebKit would send to that URL,
/// never the rest of the panel's cookie jar.
///
/// A loopback listener stands in for two sites: `localhost` and `127.0.0.1`
/// reach the same port but are different hosts. The page on `localhost` sets a
/// session cookie, then each test downloads from one host and reads the Cookie
/// header the listener received.
///
/// Host-required (`c11Tests`): WebKit needs the app's main bundle to start its
/// network process.
final class BrowserContextMenuDownloadCookieTests: XCTestCase {
    private static let cookieName = RecordingHTTPListener.cookieName

    @MainActor
    func testCrossSiteDownloadCarriesNoCookieFromThePageSite() throws {
        let server = try RecordingHTTPListener()
        defer { server.stop() }
        let fixture = try loadPageThatSetsSessionCookie(server: server)

        let target = URL(string: "http://127.0.0.1:\(server.port)/cross-site.bin")!
        let header = try cookieHeaderForContextMenuDownload(of: target, fixture: fixture, server: server)

        XCTAssertFalse(
            header.contains(Self.cookieName),
            "A download from another site received the page site's cookie: \(header)"
        )
    }

    @MainActor
    func testSameSiteDownloadKeepsThePageSiteCookie() throws {
        let server = try RecordingHTTPListener()
        defer { server.stop() }
        let fixture = try loadPageThatSetsSessionCookie(server: server)

        let target = URL(string: "http://localhost:\(server.port)/same-site.bin")!
        let header = try cookieHeaderForContextMenuDownload(of: target, fixture: fixture, server: server)

        XCTAssertTrue(
            header.contains("\(Self.cookieName)=secret-a"),
            "A download from the page's own site lost its session cookie: \(header)"
        )
    }

    // MARK: - Fixture

    private struct Fixture {
        let webView: CmuxWebView
        let downloads: RecordingDownloadDelegate
        let navigation: NavigationWaiter
    }

    @MainActor
    private func loadPageThatSetsSessionCookie(server: RecordingHTTPListener) throws -> Fixture {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let navigation = NavigationWaiter()
        let downloads = RecordingDownloadDelegate()
        webView.navigationDelegate = navigation
        webView.contextMenuDownloadDelegate = downloads

        let loaded = expectation(description: "page loaded")
        navigation.onFinish = { loaded.fulfill() }
        navigation.onFail = { error in
            XCTFail("Page load failed: \(error)")
            loaded.fulfill()
        }
        _ = webView.load(URLRequest(url: URL(string: "http://localhost:\(server.port)/page")!))
        wait(for: [loaded], timeout: 15)

        let jarRead = expectation(description: "cookie jar read")
        var jar: [HTTPCookie] = []
        configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            jar = cookies
            jarRead.fulfill()
        }
        wait(for: [jarRead], timeout: 5)
        XCTAssertTrue(
            jar.contains { $0.name == Self.cookieName },
            "The page did not leave its session cookie in the panel's jar"
        )
        return Fixture(webView: webView, downloads: downloads, navigation: navigation)
    }

    @MainActor
    private func cookieHeaderForContextMenuDownload(
        of target: URL,
        fixture: Fixture,
        server: RecordingHTTPListener
    ) throws -> String {
        let received = expectation(description: "listener received \(target.path)")
        server.onRequest = { request in
            if request.path == target.path { received.fulfill() }
        }
        let finished = expectation(description: "download finished")
        fixture.downloads.onSettled = { finished.fulfill() }

        fixture.webView.startContextMenuDownload(
            target,
            sender: nil,
            fallbackAction: nil,
            fallbackTarget: nil,
            traceID: "c11-487-test"
        )

        wait(for: [received], timeout: 15)
        let request = try XCTUnwrap(server.requests.last { $0.path == target.path })
        wait(for: [finished], timeout: 15)
        XCTAssertNil(fixture.downloads.failure, "The download failed: \(String(describing: fixture.downloads.failure))")
        return request.headers["cookie"] ?? ""
    }
}

// MARK: - Helpers

private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?
    var onFail: ((Error) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
        onFinish = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFail?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFail?(error)
    }
}

/// Saves each download into a scratch directory and reports when it settles.
private final class RecordingDownloadDelegate: NSObject, WKDownloadDelegate {
    var onSettled: (() -> Void)?
    private(set) var failure: Error?
    private let directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("c11-487-downloads-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        completionHandler(directory.appendingPathComponent(UUID().uuidString, isDirectory: false))
    }

    func downloadDidFinish(_ download: WKDownload) {
        settle()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        failure = error
        settle()
    }

    private func settle() {
        let callback = onSettled
        onSettled = nil
        callback?()
    }
}

/// A loopback-only HTTP/1.1 listener that records each request's path and
/// headers. `/page` answers with HTML that sets the session cookie; every other
/// path answers with a small binary body. Callbacks arrive on the main queue.
private final class RecordingHTTPListener {
    struct Request {
        let path: String
        /// Header names lowercased; repeated headers joined with "; ".
        let headers: [String: String]
    }

    static let cookieName = "site_a_session"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "c11.tests.c11-487.listener")
    private(set) var requests: [Request] = []
    private(set) var port: UInt16 = 0
    var onRequest: ((Request) -> Void)?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        var startError: NWError?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, startError == nil,
              let port = listener.port?.rawValue else {
            listener.cancel()
            throw startError ?? NWError.posix(.ETIMEDOUT)
        }
        self.port = port
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(on: connection, buffer: Data())
    }

    private func receiveHead(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(on: connection, head: buffer.subdata(in: buffer.startIndex..<end.lowerBound))
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveHead(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, head: Data) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let path = requestLine.count > 1 ? String(requestLine[1]) : "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0); \(value)" } ?? value
        }
        let request = Request(path: path, headers: headers)
        DispatchQueue.main.async {
            self.requests.append(request)
            self.onRequest?(request)
        }

        let body: Data
        var responseHeaders: [String]
        if path == "/page" {
            body = Data("<!doctype html><title>site a</title><p>site a</p>".utf8)
            responseHeaders = [
                "Content-Type: text/html; charset=utf-8",
                "Set-Cookie: \(Self.cookieName)=secret-a; Path=/",
            ]
        } else {
            body = Data("c11-487 download body".utf8)
            responseHeaders = ["Content-Type: application/octet-stream"]
        }
        responseHeaders.append("Content-Length: \(body.count)")
        responseHeaders.append("Connection: close")
        var response = Data(("HTTP/1.1 200 OK\r\n" + responseHeaders.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
