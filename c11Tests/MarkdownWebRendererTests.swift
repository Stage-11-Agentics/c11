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
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        try image.write(to: folder.appendingPathComponent("local.png"))
        let text = "# Reader\n\n```mermaid\ngraph TD\nA-->B\n```\n\n"
            + (1...80).map { "## Section \($0)\n\nParagraph \($0).\n\n" }.joined()
            + "![local](local.png)\n<script>window.hostileExecuted=true</script>\n<img src=x onerror='window.hostileExecuted=true'>\n[jump](javascript:alert(1))\n![remote](https://example.invalid/canary.png)\n[executable](./evil.command)\n[application](file:///System/Applications/Calculator.app)\n"
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
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)
        XCTAssertFalse(renderer.failure)
        XCTAssertEqual(renderer.webView.pageZoom, 1)
        XCTAssertFalse(renderer.webView.allowsMagnification)
        let initial = try await call(renderer, "visible") as? [String: Any]
        XCTAssertEqual(initial?["font_scale"] as? Double, 1.3)
        XCTAssertEqual((initial?["theme"] as? [String: Any])?["choice"] as? String, "dark")
        XCTAssertEqual((initial?["typeface"] as? [String: Any])?["choice"] as? String, "mono")
        let secure = try await evaluate(renderer, "({executed:window.hostileExecuted===true,remote:document.querySelectorAll('[src^=https]').length,svg:document.querySelectorAll('svg').length})") as? [String: Any]
        XCTAssertEqual(secure?["executed"] as? Bool, false)
        XCTAssertEqual(secure?["remote"] as? Int, 0)
        XCTAssertGreaterThan(secure?["svg"] as? Int ?? 0, 0, "Mermaid must render offline through the custom scheme")
        let imageLoaded: Any = try await withCheckedThrowingContinuation { continuation in
            renderer.webView.callAsyncJavaScript(
            "const img=document.querySelector('img[src^=\"c11md-asset:\"]'); if(!img)return false; await img.decode(); return img.naturalWidth===1;",
            arguments: [:], in: nil, in: .page) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(imageLoaded as? Bool, true, "Scoped image bytes must load through WebKit")
        _ = try await call(renderer, "scrollToHeading", arguments: ["Section 40"])
        let before = try await call(renderer, "visible") as? [String: Any]
        let firstLine = (before?["lines"] as? [String: Any])?["first"] as? Int
        XCTAssertGreaterThan(firstLine ?? 0, 1, "The witness must be scrolled away from the top")
        let beforeY = try await evaluate(renderer, "document.getElementById('c11md-h-section-40').getBoundingClientRect().top") as? Double
        // A real file-watcher reload that changes layout above the viewport.
        let changed = text.replacingOccurrences(of: "Paragraph 1.", with: String(repeating: "Expanded introduction. ", count: 100)) + "\nAppended paragraph.\n"
        try changed.write(to: path, atomically: true, encoding: .utf8)
        await rendered(renderer, revision: 2)
        let after = try await call(renderer, "visible") as? [String: Any]
        XCTAssertEqual((after?["lines"] as? [String: Any])?["first"] as? Int, firstLine)
        let afterY = try await evaluate(renderer, "document.getElementById('c11md-h-section-40').getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(afterY), try XCTUnwrap(beforeY), accuracy: 1)
        XCTAssertEqual(panel.content, changed)
        panel.zoomIn()
        let scaled = try await call(renderer, "visible") as? [String: Any]
        XCTAssertEqual(scaled?["font_scale"] as? Double, 1.4)
        XCTAssertEqual(renderer.webView.pageZoom, 1)
        XCTAssertTrue(panel.ensureRenderer() === renderer, "re-showing a panel reuses its web view")
    }

    func testEvictionWaitsForQueryAndRestoresPositionModeFindAndLatestContent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-eviction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reader.md")
        let text = "# Reader\n\n" + (1...80).map { "## Section \($0)\n\nParagraph \($0).\n\n" }.joined()
        try text.write(to: path, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        var others: [MarkdownPanel] = []
        defer { panel.close(); others.forEach { $0.close() } }
        let host = UUID()
        panel.setRendererVisible(true, hostID: host)
        var first: MarkdownWebRenderer? = panel.ensureRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = first!.webView
        defer { window.contentView = nil; window.close() }
        await rendered(first!, revision: 1)
        _ = try await call(first!, "setSourceMode", arguments: [true])
        _ = try await call(first!, "find", arguments: ["Paragraph 40"])
        _ = try await call(first!, "scrollToLine", arguments: [160, 7.25])
        let beforeValue = try await call(first!, "visible")
        let before = try XCTUnwrap(beforeValue as? [String: Any])
        let position = try XCTUnwrap(MarkdownReadingPosition(state: before))
        XCTAssertGreaterThan(position.line, 1)
        XCTAssertGreaterThan(position.offset, 0, "Approved offset bridge must be present")
        XCTAssertTrue(position.sourceMode)
        XCTAssertEqual(position.findQuery, "Paragraph 40")
        let evicted = expectation(description: "oldest hidden reader evicted")
        let token = MarkdownRendererCache.shared.evictions.first(where: { $0 == panel.id }).sink { _ in evicted.fulfill() }
        first!.call("visible") // A genuine asynchronous query pins the renderer.
        XCTAssertTrue(first!.hasQueriesInFlight)
        window.contentView = nil
        panel.setRendererVisible(false, hostID: host)
        for _ in 0..<5 {
            let other = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
            others.append(other)
            _ = other.ensureRenderer()
        }
        XCTAssertNotNil(panel.renderer, "An in-flight query must prevent eviction")
        await fulfillment(of: [evicted], timeout: 30)
        withExtendedLifetime(token) {}
        XCTAssertNil(panel.renderer)
        XCTAssertEqual(panel.readingPosition, position)
        first = nil
        let changed = text + "\nLatest content while evicted.\n"
        let reloaded = expectation(description: "evicted model reload")
        let contentToken = panel.$content.first(where: { $0 == changed }).sink { _ in reloaded.fulfill() }
        try changed.write(to: path, atomically: true, encoding: .utf8)
        await fulfillment(of: [reloaded], timeout: 10)
        withExtendedLifetime(contentToken) {}
        XCTAssertNil(panel.renderer, "File reload must remain model-only while evicted")
        panel.setRendererVisible(true, hostID: host)
        let recreated = panel.ensureRenderer()
        window.contentView = recreated.webView
        await rendered(recreated, revision: 1)
        let afterValue = try await call(recreated, "visible")
        let after = try XCTUnwrap(afterValue as? [String: Any])
        let restored = try XCTUnwrap(MarkdownReadingPosition(state: after))
        XCTAssertEqual(restored.line, position.line)
        XCTAssertEqual(restored.offset, position.offset, accuracy: 1)
        XCTAssertEqual(restored.sourceMode, position.sourceMode)
        XCTAssertEqual(restored.findQuery, position.findQuery)
        XCTAssertTrue(panel.content.contains("Latest content while evicted."))
        XCTAssertEqual(recreated.webView.pageZoom, 1)
    }

    func testEveryPresentationFieldInvalidatesSessionAutosaveFingerprint() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newMarkdownPanel(inPane: pane, filePath: nil, focus: false))
        defer { for value in workspace.panels.values { value.close() } }
        var snapshot = SessionMarkdownPanelSnapshot(fontScale: 1, theme: "system", typeface: "theme", outlineOpen: nil)
        panel.applyRestoredPresentation(snapshot)
        var before = manager.sessionAutosaveFingerprint()
        for field in 0..<4 {
            switch field {
            case 0: snapshot.fontScale = 1.4
            case 1: snapshot.theme = "dark"
            case 2: snapshot.typeface = "mono"
            default: snapshot.outlineOpen = false
            }
            panel.applyRestoredPresentation(snapshot)
            let after = manager.sessionAutosaveFingerprint()
            XCTAssertNotEqual(after, before, "Presentation field \(field) must trigger autosave")
            before = after
        }
        XCTAssertNil(panel.renderer, "Autosave must not create WebKit for hidden documents")
    }

    func testClosingPanelReleasesItsRendererAndScopedHandlers() {
        weak var retained: MarkdownWebRenderer?
        autoreleasepool {
            let panel = MarkdownPanel(workspaceId: UUID())
            retained = panel.ensureRenderer()
            XCTAssertNotNil(retained)
            panel.close()
            XCTAssertNil(panel.renderer)
        }
        XCTAssertNil(retained, "Closing must break WKUserContentController's message-handler cycle")
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
