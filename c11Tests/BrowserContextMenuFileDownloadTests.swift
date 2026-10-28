import XCTest
import WebKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-495. Download Image and Download Linked File resolve their URL with the
/// page's own JavaScript, so a web page could name any local path. Only a
/// local page that was settled when the menu opened may save a `file:` URL,
/// only from the folder WebKit lets that page read, only a regular file, and
/// nothing about it may block the main thread.
///
/// Each test opens the menu with `noteContextMenuOpened()`, as `willOpenMenu`
/// does, and records the download indicator, which must end where it started.
///
/// Host-required (`c11Tests`): WebKit needs the app's main bundle to start its
/// processes.
final class BrowserContextMenuFileDownloadTests: XCTestCase {
    fileprivate var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-495-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    @MainActor
    func testWebPageCannotSaveALocalFile() throws {
        let fixture = try Fixture(test: self, page: .web)
        let secret = try writeFile("secret.txt", bytes: Data("local secret".utf8))

        fixture.download(secret)

        try fixture.waitForRefusal()
    }

    @MainActor
    func testLocalPageSavesAFileFromItsFolder() throws {
        let page = try writeFile("site/page.html", bytes: Data("<!doctype html><p>local page</p>".utf8))
        let fixture = try Fixture(test: self, page: .local(page))
        let bytes = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let image = try writeFile("site/images/photo.png", bytes: bytes)

        fixture.download(image)

        let saved = fixture.destinations.directory.appendingPathComponent("saved-photo.png")
        let copied = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.contents(atPath: saved.path) == bytes },
            object: nil
        )
        wait(for: [copied], timeout: 10)
        XCTAssertEqual(fixture.destinations.requestedNames, ["photo.png"])
        try fixture.waitForIndicator([true, false, true, false])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.destinations.directory.path)
            .filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [], "The staged copy was left behind")
    }

    @MainActor
    func testLocalPageCannotSaveAFileOutsideItsFolder() throws {
        let page = try writeFile("site/page.html", bytes: Data("<!doctype html><p>local page</p>".utf8))
        let fixture = try Fixture(test: self, page: .local(page))
        let secret = try writeFile("elsewhere/secret.txt", bytes: Data("local secret".utf8))

        fixture.download(secret)

        try fixture.waitForRefusal()
    }

    @MainActor
    func testLocalPageCannotSaveAFIFO() throws {
        let page = try writeFile("page.html", bytes: Data("<!doctype html><p>local page</p>".utf8))
        let fixture = try Fixture(test: self, page: .local(page))
        let fifo = scratch.appendingPathComponent("pipe.png")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0, "mkfifo failed: \(errno)")

        // A FIFO with no writer blocks whoever opens it; the menu must refuse
        // it without opening it.
        fixture.download(fifo)

        try fixture.waitForRefusal()
    }

    /// The menu opened on a web page that then navigated to a local page: the
    /// document that answered the menu was the web page.
    @MainActor
    func testFileSaveNeedsALocalPageWhenTheMenuOpened() throws {
        let fixture = try Fixture(test: self, page: .web)
        let page = try writeFile("page.html", bytes: Data("<!doctype html><p>local page</p>".utf8))
        let secret = try writeFile("secret.txt", bytes: Data("local secret".utf8))
        try fixture.load(.local(page), noteMenu: false)
        XCTAssertEqual(fixture.webView.url?.isFileURL, true)

        fixture.download(secret)

        try fixture.waitForRefusal()
    }

    /// The menu opened on a local page that then started loading a web page.
    @MainActor
    func testFileSaveRefusedWhileThePageNavigatesAway() throws {
        let page = try writeFile("page.html", bytes: Data("<!doctype html><p>local page</p>".utf8))
        let fixture = try Fixture(test: self, page: .local(page))
        let image = try writeFile("photo.png", bytes: Data("local image".utf8))
        _ = fixture.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:9/away")!))

        fixture.download(image)

        try fixture.waitForRefusal()
    }

    /// data: downloads share the save step with file: downloads and stay
    /// available to web pages.
    @MainActor
    func testWebPageStillSavesADataURL() throws {
        let fixture = try Fixture(test: self, page: .web)
        let bytes = Data("c11-495 inline image".utf8)
        let dataURL = URL(string: "data:image/png;base64,\(bytes.base64EncodedString())")!

        fixture.download(dataURL)

        let saved = fixture.destinations.directory.appendingPathComponent("saved-image.png")
        let written = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.contents(atPath: saved.path) == bytes },
            object: nil
        )
        wait(for: [written], timeout: 10)
        XCTAssertEqual(fixture.destinations.requestedNames, ["image.png"])
    }

    // MARK: - Fixture

    private func writeFile(_ relativePath: String, bytes: Data) throws -> URL {
        let url = scratch.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }
}

private enum Page {
    case web
    case local(URL)
}

@MainActor
private final class Fixture {
    let webView: CmuxWebView
    let destinations: DestinationRecorder
    private unowned let test: XCTestCase
    private let navigation = FinishWaiter()
    private(set) var indicator: [Bool] = []
    private var onIndicatorChange: (() -> Void)?

    init(test: BrowserContextMenuFileDownloadTests, page: Page) throws {
        self.test = test
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let saves = test.scratch.appendingPathComponent("saves", isDirectory: true)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        destinations = DestinationRecorder(directory: saves)
        webView.navigationDelegate = navigation
        webView.contextMenuSaveDestinationProvider = destinations.provide
        webView.onContextMenuDownloadStateChanged = { [unowned self] state in
            indicator.append(state)
            onIndicatorChange?()
        }
        try load(page, noteMenu: true)
    }

    func load(_ page: Page, noteMenu: Bool) throws {
        let finished = test.expectation(description: "page loaded")
        navigation.onSettled = { error in
            if let error { XCTFail("Page load failed: \(error)") }
            finished.fulfill()
        }
        switch page {
        case .web:
            XCTAssertNotNil(webView.loadHTMLString("<!doctype html><p>site a</p>", baseURL: URL(string: "http://site-a.test/page")))
        case .local(let file):
            XCTAssertNotNil(webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent()))
        }
        test.wait(for: [finished], timeout: 15)
        if noteMenu {
            webView.noteContextMenuOpened()
        }
    }

    func download(_ url: URL) {
        webView.startContextMenuDownload(
            url,
            sender: nil,
            fallbackAction: nil,
            fallbackTarget: nil,
            traceID: "c11-495-test"
        )
    }

    /// The menu turned the indicator on and off and never asked where to save.
    func waitForRefusal() throws {
        try waitForIndicator([true, false])
        XCTAssertEqual(destinations.requestedNames, [], "A refused file reached the save step")
    }

    func waitForIndicator(_ expected: [Bool]) throws {
        if indicator.count < expected.count {
            let reached = test.expectation(description: "indicator changed \(expected.count) times")
            onIndicatorChange = { [unowned self] in
                guard indicator.count >= expected.count else { return }
                onIndicatorChange = nil
                reached.fulfill()
            }
            test.wait(for: [reached], timeout: 10)
        }
        XCTAssertEqual(indicator, expected)
    }
}

// MARK: - Helpers

private final class FinishWaiter: NSObject, WKNavigationDelegate {
    var onSettled: ((Error?) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        settle(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        settle(error)
    }

    private func settle(_ error: Error?) {
        let callback = onSettled
        onSettled = nil
        callback?(error)
    }
}

/// Stands in for the save panel: records each suggested name and answers with
/// `saved-<name>` in its directory.
private final class DestinationRecorder {
    let directory: URL
    private(set) var requestedNames: [String] = []

    init(directory: URL) {
        self.directory = directory
    }

    func provide(_ suggestedName: String, _ completion: @escaping (URL?) -> Void) {
        requestedNames.append(suggestedName)
        completion(directory.appendingPathComponent("saved-\(suggestedName)"))
    }
}
