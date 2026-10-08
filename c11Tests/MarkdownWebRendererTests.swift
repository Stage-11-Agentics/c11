import AppKit
import Combine
import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Real WebKit + the app's bundled offline renderer. No fake page or JS engine.
@MainActor
final class MarkdownWebRendererTests: XCTestCase {
    func testBundledRendererMermaidSettingsHostileContentAndReload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reader.md")
        let text = "# Reader\n\n```mermaid\ngraph TD\nA-->B\n```\n\n"
            + (1...80).map { "## Section \($0)\n\nParagraph \($0).\n\n" }.joined()
            + "<script>window.hostileExecuted=true</script>\n<img src=x onerror='window.hostileExecuted=true'>\n[jump](javascript:alert(1))\n![remote](https://example.invalid/canary.png)\n"
        try text.write(to: path, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        defer { panel.close() }
        XCTAssertNil(panel.renderer)
        panel.applyRestoredPresentation(SessionMarkdownPanelSnapshot(fontScale: 1.3, theme: "dark", typeface: "mono", outlineOpen: false))
        let renderer = panel.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        // Attaching to a non-visible window supplies AppKit layout without any
        // screen activation, clicks, or changes to the operator's workspace.
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)
        XCTAssertFalse(renderer.failure)
        XCTAssertEqual(renderer.webView.pageZoom, 1)
        XCTAssertFalse(renderer.webView.allowsMagnification)
        XCTAssertEqual(renderer.state["font_scale"] as? Double, 1.3)
        XCTAssertEqual((renderer.state["theme"] as? [String: Any])?["choice"] as? String, "dark")
        XCTAssertEqual((renderer.state["typeface"] as? [String: Any])?["choice"] as? String, "mono")
        let secure = try await evaluate(renderer, "({executed:window.hostileExecuted===true,remote:document.querySelectorAll('[src^=https]').length,svg:document.querySelectorAll('svg').length})") as? [String: Any]
        XCTAssertEqual(secure?["executed"] as? Bool, false)
        XCTAssertEqual(secure?["remote"] as? Int, 0)
        XCTAssertGreaterThan(secure?["svg"] as? Int ?? 0, 0, "Mermaid must render offline through the custom scheme")
        _ = try await call(renderer, "scrollToHeading", arguments: ["Section 40"])
        let before = try await call(renderer, "visible") as? [String: Any]
        let firstLine = (before?["lines"] as? [String: Int])?["first"]
        // A real file-watcher reload, not a direct page load call.
        try (text + "\nAppended paragraph.\n").write(to: path, atomically: true, encoding: .utf8)
        await rendered(renderer, revision: 2)
        let after = try await call(renderer, "visible") as? [String: Any]
        XCTAssertEqual((after?["lines"] as? [String: Int])?["first"], firstLine)
        XCTAssertEqual(panel.content, text + "\nAppended paragraph.\n")
        panel.zoomIn()
        let scaled = try await call(renderer, "visible") as? [String: Any]
        XCTAssertEqual(scaled?["font_scale"] as? Double, 1.4)
        XCTAssertEqual(renderer.webView.pageZoom, 1)
        XCTAssertTrue(panel.ensureRenderer() === renderer, "re-showing a panel reuses its web view")
    }

    private func rendered(_ renderer: MarkdownWebRenderer, revision: Int) async {
        let done = expectation(description: "renderer settled revision \(revision)")
        let token = renderer.$renderedRevision.first(where: { $0 == revision }).sink { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 30)
        withExtendedLifetime(token) {}
    }

    private func call(_ renderer: MarkdownWebRenderer, _ method: String, arguments: [Any] = []) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            renderer.call(method, arguments: arguments) { continuation.resume(with: $0) }
        }
    }

    private func evaluate(_ renderer: MarkdownWebRenderer, _ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            renderer.webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value ?? NSNull()) }
            }
        }
    }
}
