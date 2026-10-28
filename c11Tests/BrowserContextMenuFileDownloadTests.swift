import XCTest
import WebKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-495. Download Image and Download Linked File resolve their URL with the
/// page's own JavaScript, so a web page could name any local path. Only a page
/// that is itself a local file may save a `file:` URL, the target must be a
/// regular file, and nothing about it may block the main thread.
///
/// Host-required (`c11Tests`): WebKit needs the app's main bundle to start its
/// processes.
final class BrowserContextMenuFileDownloadTests: XCTestCase {
    private var scratch: URL!

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
        let webView = try loadedWebView(baseURL: URL(string: "http://site-a.test/page")!)
        let secret = try writeFile("secret.txt", bytes: Data("local secret".utf8))
        let destinations = DestinationRecorder(directory: scratch)
        webView.contextMenuSaveDestinationProvider = destinations.provide

        let fellBack = expectation(description: "menu fell back to WebKit's own action")
        let fallback = FallbackRecorder { fellBack.fulfill() }
        webView.startContextMenuDownload(
            secret,
            sender: nil,
            fallbackAction: #selector(FallbackRecorder.record(_:)),
            fallbackTarget: fallback,
            traceID: "c11-495-web"
        )
        wait(for: [fellBack], timeout: 5)

        XCTAssertEqual(destinations.requestedNames, [], "A web page reached the save step for a local file")
    }

    @MainActor
    func testLocalFilePageSavesARegularFile() throws {
        let page = try writeFile("page.html", bytes: Data("<!doctype html><p>local page</p>".utf8))
        let webView = try loadedWebView(fileURL: page)
        let bytes = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let image = try writeFile("photo.png", bytes: bytes)
        let destinations = DestinationRecorder(directory: scratch)
        webView.contextMenuSaveDestinationProvider = destinations.provide

        webView.startContextMenuDownload(
            image,
            sender: nil,
            fallbackAction: nil,
            fallbackTarget: nil,
            traceID: "c11-495-file"
        )

        let saved = destinations.directory.appendingPathComponent("saved-photo.png")
        let copied = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.contents(atPath: saved.path) == bytes },
            object: nil
        )
        wait(for: [copied], timeout: 10)
        XCTAssertEqual(destinations.requestedNames, ["photo.png"])
    }

    @MainActor
    func testLocalFilePageCannotSaveAFIFO() throws {
        let page = try writeFile("page.html", bytes: Data("<!doctype html><p>local page</p>".utf8))
        let webView = try loadedWebView(fileURL: page)
        let fifo = scratch.appendingPathComponent("pipe.png")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0, "mkfifo failed: \(errno)")
        let destinations = DestinationRecorder(directory: scratch)
        webView.contextMenuSaveDestinationProvider = destinations.provide

        // A FIFO with no writer blocks whoever opens it; the menu must refuse
        // it without opening it, and the main thread must stay free.
        let fellBack = expectation(description: "menu fell back to WebKit's own action")
        let fallback = FallbackRecorder { fellBack.fulfill() }
        webView.startContextMenuDownload(
            fifo,
            sender: nil,
            fallbackAction: #selector(FallbackRecorder.record(_:)),
            fallbackTarget: fallback,
            traceID: "c11-495-fifo"
        )
        wait(for: [fellBack], timeout: 5)

        XCTAssertEqual(destinations.requestedNames, [], "A FIFO reached the save step")
    }

    /// data: downloads share the save step with file: downloads and stay
    /// available to web pages.
    @MainActor
    func testWebPageStillSavesADataURL() throws {
        let webView = try loadedWebView(baseURL: URL(string: "http://site-a.test/page")!)
        let bytes = Data("c11-495 inline image".utf8)
        let dataURL = URL(string: "data:image/png;base64,\(bytes.base64EncodedString())")!
        let destinations = DestinationRecorder(directory: scratch)
        webView.contextMenuSaveDestinationProvider = destinations.provide

        webView.startContextMenuDownload(
            dataURL,
            sender: nil,
            fallbackAction: nil,
            fallbackTarget: nil,
            traceID: "c11-495-data"
        )

        let saved = destinations.directory.appendingPathComponent("saved-image.png")
        let written = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.contents(atPath: saved.path) == bytes },
            object: nil
        )
        wait(for: [written], timeout: 10)
        XCTAssertEqual(destinations.requestedNames, ["image.png"])
    }

    // MARK: - Fixture

    private func writeFile(_ name: String, bytes: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    @MainActor
    private func loadedWebView(baseURL: URL) throws -> CmuxWebView {
        try loadedWebView { $0.loadHTMLString("<!doctype html><p>site a</p>", baseURL: baseURL) }
    }

    @MainActor
    private func loadedWebView(fileURL: URL) throws -> CmuxWebView {
        try loadedWebView { $0.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent()) }
    }

    @MainActor
    private func loadedWebView(_ load: (CmuxWebView) -> WKNavigation?) throws -> CmuxWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let navigation = FinishWaiter()
        webView.navigationDelegate = navigation
        let finished = expectation(description: "page loaded")
        navigation.onFinish = { finished.fulfill() }
        XCTAssertNotNil(load(webView))
        wait(for: [finished], timeout: 15)
        webView.navigationDelegate = nil
        return webView
    }
}

// MARK: - Helpers

private final class FinishWaiter: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
        onFinish = nil
    }
}

/// Stands in for the save panel: records each suggested name and answers with
/// `saved-<name>` in the scratch directory.
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

/// The target of the menu's fallback action (WebKit's own menu item).
private final class FallbackRecorder: NSObject {
    private let onRecord: () -> Void

    init(onRecord: @escaping () -> Void) {
        self.onRecord = onRecord
    }

    @objc func record(_ sender: Any?) {
        onRecord()
    }
}
