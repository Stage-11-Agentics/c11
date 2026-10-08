import AppKit
import Combine
import SwiftUI
import XCTest
import WebKit
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

    func testPanelNavigationOwnsHistoryAndLeavesItsIdentityStable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-panel-navigation-\(UUID().uuidString)")
        let repository = root.appendingPathComponent("repo")
        let documents = repository.appendingPathComponent("docs")
        let source = documents.appendingPathComponent("reader.md")
        let target = documents.appendingPathComponent("target.md")
        let outside = root.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Reader\n\nSource content.\n".write(to: source, atomically: true, encoding: .utf8)
        let targetMarkdown = "# Target\n\n## Details\n\n" + (1...30).map { "Target content \($0).\n\n" }.joined()
        try targetMarkdown.write(to: target, atomically: true, encoding: .utf8)
        try "# Outside\n".write(to: outside, atomically: true, encoding: .utf8)

        let workspaceID = UUID()
        let panel = MarkdownPanel(workspaceId: workspaceID, filePath: source.path)
        defer { panel.close() }
        let panelID = panel.id
        let renderer = panel.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)

        let firstNavigation = await panel.navigate(to: target, fragment: "details", origin: .palette)
        XCTAssertEqual(firstNavigation, .navigated)
        await rendered(renderer, revision: 2)
        XCTAssertEqual(panel.id, panelID)
        XCTAssertEqual(panel.workspaceId, workspaceID)
        XCTAssertEqual(panel.filePath, target.path)
        XCTAssertEqual(panel.navigationHistory.current?.origin, .palette)
        XCTAssertTrue(panel.canNavigateBack)
        let targetStateValue = try await call(renderer, "visible")
        let targetState = try XCTUnwrap(targetStateValue as? [String: Any])
        XCTAssertEqual((targetState["heading"] as? [String: Any])?["text"] as? String, "Details")

        let backOutcome = await panel.navigateBack()
        XCTAssertEqual(backOutcome, .navigated)
        await rendered(renderer, revision: 3)
        XCTAssertEqual(panel.filePath, source.path)
        XCTAssertTrue(panel.canNavigateForward)
        let forwardOutcome = await panel.navigateForward()
        XCTAssertEqual(forwardOutcome, .navigated)
        await rendered(renderer, revision: 4)
        XCTAssertEqual(panel.filePath, target.path)
        XCTAssertEqual(panel.id, panelID)
        XCTAssertEqual(panel.workspaceId, workspaceID)

        let entriesBeforeRejection = panel.navigationHistory.entries.count
        let rejectedNavigation = await panel.navigate(to: outside, fragment: nil, origin: .backlink)
        XCTAssertEqual(rejectedNavigation, .outsideScope)
        XCTAssertEqual(panel.filePath, target.path)
        XCTAssertEqual(panel.navigationHistory.entries.count, entriesBeforeRejection)
    }

    func testReloadFromPreviousDocumentCannotReplaceNavigatedContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-stale-reload-\(UUID().uuidString)")
        let repository = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = repository.appendingPathComponent("source.md")
        let target = repository.appendingPathComponent("target.md")
        try "# Source\n".write(to: source, atomically: true, encoding: .utf8)
        try "# Target\n".write(to: target, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: source.path)
        defer { panel.close() }
        let navigation = await panel.navigate(to: target, fragment: nil, origin: .agentCLI)
        XCTAssertEqual(navigation, .navigated)
        XCTAssertEqual(panel.filePath, target.path)
        XCTAssertEqual(panel.content, "# Target\n")

        // This is a watcher result already read from source.md before stopFileWatcher
        // canceled the debounce item. It must not affect target.md or availability.
        panel.applyExternalContent("# Stale source\n", forPath: source.path)
        panel.applyExternalContent(nil, forPath: source.path)
        XCTAssertEqual(panel.content, "# Target\n")
        XCTAssertFalse(panel.isFileUnavailable)
    }

    func testSameDocumentPositionRestoreCannotUndoPageAppliedAnchor() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-navigation-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reader.md")
        let middle = (1...24).map { "Middle paragraph \($0).\n\n" }.joined()
        let tail = (1...24).map { "Bottom paragraph \($0).\n\n" }.joined()
        try ("# Guide\n\n## Middle\n\n" + middle + "## Bottom\n\n" + tail)
            .write(to: path, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        defer { panel.close() }
        let renderer = panel.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)

        let userContentController = renderer.webView.configuration.userContentController
        let scriptProbe = MarkdownWebScriptMessageProbe()
        userContentController.add(scriptProbe, name: "c11mdTestProbe")
        defer { userContentController.removeScriptMessageHandler(forName: "c11mdTestProbe") }
        let sourceModeStarted = expectation(description: "the older restore reached setSourceMode")
        let sourceModeReleased = expectation(description: "the older restore continuation resumed")
        scriptProbe.onMessage = { body in
            switch body["type"] as? String {
            case "source-mode-held": sourceModeStarted.fulfill()
            case "source-mode-released": sourceModeReleased.fulfill()
            default: break
            }
        }
        let installed = try await evaluateAsync(renderer, #"""
            const original = window.c11md;
            window.__markdownRestoreScrolls = 0;
            window.c11md = Object.freeze({
              ...original,
              setSourceMode: async (...args) => {
                const state = await original.setSourceMode(...args);
                window.webkit.messageHandlers.c11mdTestProbe.postMessage({type: 'source-mode-held'});
                await new Promise(resolve => { window.__releaseMarkdownSourceMode = resolve; });
                window.webkit.messageHandlers.c11mdTestProbe.postMessage({type: 'source-mode-released'});
                return state;
              },
              scrollToLine: async (...args) => {
                window.__markdownRestoreScrolls += 1;
                return original.scrollToLine(...args);
              }
            });
            window.__releaseMarkdownSourceMode = () => false;
            return true;
            """#)
        XCTAssertEqual(installed as? Bool, true)

        var oldPosition = MarkdownReadingPosition()
        oldPosition.sourceMode = true
        oldPosition.line = 1
        let oldToken = panel.beginNavigationIntent()
        renderer.navigateWithinDocument(position: oldPosition, fragment: nil, navigationToken: oldToken)
        await fulfillment(of: [sourceModeStarted], timeout: 10)

        // The page applies this anchor before reporting the link to native.
        let appliedValue = try await call(renderer, "navigateFragment", arguments: ["bottom"])
        let applied = try XCTUnwrap(appliedValue as? [String: Any])
        XCTAssertEqual(applied["ok"] as? Bool, true)
        XCTAssertEqual((applied["heading"] as? [String: Any])?["text"] as? String, "Bottom")
        let bottomTopBeforeValue = try await evaluate(
            renderer,
            "document.getElementById('c11md-h-bottom').getBoundingClientRect().top"
        )
        let bottomTopBeforeRelease = try XCTUnwrap(bottomTopBeforeValue as? Double)
        let tokenBeforeAnchorReport = panel.currentNavigationToken
        let anchorTask = try XCTUnwrap(renderer.routeLink("#bottom", modifiers: [:], position: MarkdownReadingPosition()))
        XCTAssertGreaterThan(panel.currentNavigationToken, tokenBeforeAnchorReport, "Page-applied anchors reserve their navigation generation synchronously")
        await anchorTask.value
        XCTAssertEqual(panel.navigationHistory.current?.target.fragment, "bottom")

        let released = try await evaluate(renderer, "(window.__releaseMarkdownSourceMode(), true)") as? Bool
        XCTAssertEqual(released, true)
        await fulfillment(of: [sourceModeReleased], timeout: 10)
        let scrollCount = try await evaluate(renderer, "window.__markdownRestoreScrolls") as? Int
        XCTAssertEqual(scrollCount, 0, "A stale restore must not submit scrollToLine after the page applied a newer anchor")
        let visibleValue = try await call(renderer, "visible")
        let visible = try XCTUnwrap(visibleValue as? [String: Any])
        XCTAssertEqual(visible["mode"] as? String, "read")
        let bottomTopAfterValue = try await evaluate(
            renderer,
            "document.getElementById('c11md-h-bottom').getBoundingClientRect().top"
        )
        let bottomTopAfterRelease = try XCTUnwrap(bottomTopAfterValue as? Double)
        XCTAssertEqual(bottomTopAfterRelease, bottomTopBeforeRelease, accuracy: 1,
                       "The old restore must not move the page away from the applied anchor")
    }

    func testSameDocumentPeekUsesResolvedPathForSymlinkedPanel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-symlink-peek-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let realFile = real.appendingPathComponent("notes.md")
        let linkedFile = linked.appendingPathComponent("notes.md")
        try "# Notes\n\n## Details\n\nSymlink preview content.\n".write(to: realFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: realFile)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: linkedFile.path)
        defer { panel.close() }
        let renderer = panel.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)

        let userContentController = renderer.webView.configuration.userContentController
        let scriptProbe = MarkdownWebScriptMessageProbe()
        userContentController.add(scriptProbe, name: "c11mdTestProbe")
        defer { userContentController.removeScriptMessageHandler(forName: "c11mdTestProbe") }
        let peekShown = expectation(description: "the symlinked same-document preview reached the page")
        scriptProbe.onMessage = { body in
            if body["type"] as? String == "peek-visible" { peekShown.fulfill() }
        }
        let installed = try await evaluateAsync(renderer, #"""
            const peek = document.querySelector('#linkPeek');
            new MutationObserver(() => {
              if (!window.__peekReported && !peek.hidden && peek.querySelector('.peek-content')) {
                window.__peekReported = true;
                window.webkit.messageHandlers.c11mdTestProbe.postMessage({type: 'peek-visible'});
              }
            }).observe(peek, {attributes: true, childList: true, subtree: true});
            return true;
            """#)
        XCTAssertEqual(installed as? Bool, true)

        renderer.routePeek("#details", requestID: 0, rect: ["x": 12, "y": 12, "height": 16])
        await fulfillment(of: [peekShown], timeout: 10)
        let peekText = try await evaluate(renderer, "document.querySelector('#linkPeek .peek-content').textContent") as? String
        XCTAssertTrue(peekText?.contains("Symlink preview content.") == true, "The same-document fallback must use resolved path identity")
    }

    func testNewMarkdownPanelRecordsDocumentLinkRootOrigin() async throws {
        _ = NSApplication.shared
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-document-link-origin-\(UUID().uuidString)")
        let repository = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer {
            workspace.teardownAllPanels()
            try? FileManager.default.removeItem(at: root)
        }
        let target = repository.appendingPathComponent("target.md")
        try "# Target\n\n## Details\n".write(to: target, atomically: true, encoding: .utf8)
        let openedPanel = try XCTUnwrap(
            workspace.newMarkdownPanel(
                inPane: pane,
                filePath: target.path,
                fragment: "details",
                focus: false,
                initialNavigationOrigin: .documentLink
            )
        )
        XCTAssertEqual(openedPanel.navigationHistory.current?.origin, .documentLink)
    }

    func testScrollToHeadingPrefersExactAndReportsAmbiguousBroaderMatches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-heading-match-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reader.md")
        try "# Guide\n\n## Install\n\nA.\n\n## Installation\n\nB.\n\n## Installing the App\n\nC.\n\n## Well Installed\n\nD.\n".write(to: path, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        defer { panel.close() }
        let renderer = panel.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)

        let exactValue = try await call(renderer, "scrollToHeading", arguments: ["Install"])
        let exact = try XCTUnwrap(exactValue as? [String: Any])
        XCTAssertEqual(exact["ok"] as? Bool, true)
        XCTAssertEqual((exact["heading"] as? [String: Any])?["text"] as? String, "Install", "exact heading text wins over its longer prefix matches")

        let prefixValue = try await call(renderer, "scrollToHeading", arguments: ["Inst"])
        let prefix = try XCTUnwrap(prefixValue as? [String: Any])
        XCTAssertEqual(prefix["ok"] as? Bool, false)
        XCTAssertEqual(prefix["ambiguous"] as? Bool, true)
        XCTAssertEqual(prefix["total"] as? Int, 3)
        XCTAssertEqual((prefix["matches"] as? [[String: Any]])?.compactMap { $0["text"] as? String }, ["Install", "Installation", "Installing the App"])

        let substringValue = try await call(renderer, "scrollToHeading", arguments: ["stall"])
        let substring = try XCTUnwrap(substringValue as? [String: Any])
        XCTAssertEqual(substring["ok"] as? Bool, false)
        XCTAssertEqual(substring["ambiguous"] as? Bool, true)
        XCTAssertEqual(substring["total"] as? Int, 4)
    }

    func testSourceModeEvictionRestoresPositionModeFindAndLatestContent() async throws {
        try await evictionRestoresReadingState(sourceMode: true)
    }

    func testNarrowReadModeEvictionRestoresReadingState() async throws {
        try await evictionRestoresReadingState(sourceMode: false)
    }

    func testReadModeEvictionRestoresInteriorLineInsideSoftWrappedParagraph() async throws {
        try await evictionRestoresReadingState(sourceMode: false, multiline: true)
    }

    private func evictionRestoresReadingState(sourceMode: Bool, multiline: Bool = false) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-eviction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reader.md")
        let text = "# Reader\n\n```mermaid\ngraph TD\nA-->B\n```\n\n" + (1...80).map { section in
            guard multiline else { return "## Section \(section)\n\nParagraph \(section).\n\n" }
            let sourceLines = ["a", "b", "c", "d"].map { label in
                "Line \(label) of \(section): " + String(repeating: "a deliberately long phrase that must wrap in the narrow reader ", count: 4)
            }
            return "## Section \(section)\n\n" + sourceLines.joined(separator: "\n") + "\n\n"
        }.joined()
        try text.write(to: path, atomically: true, encoding: .utf8)
        // In the multiline fixture, Section 20 starts on source line 141 and
        // its third paragraph source line is 145, inside one rendered block.
        let targetLine = multiline ? 145 : 160
        let findQuery = multiline ? "" : "Paragraph 40"
        let targetTextRowProbe = """
        (()=>{
          const sc=document.getElementById('scroller');
          const walker=document.createTreeWalker(document.getElementById('article'),NodeFilter.SHOW_TEXT);
          const nodes=[];
          let node;
          while((node=walker.nextNode())) nodes.push(node);
          const text=nodes.map(node=>node.data).join('');
          const start=text.indexOf('Line c of 20');
          const end=text.indexOf('Line d of 20',start);
          if(start<0||end<0) return {error:'source-line text not found',start,end,text:text.slice(0,240)};
          const boundary=offset=>{
            for(const node of nodes) {
              if(offset<=node.data.length) return [node,offset];
              offset-=node.data.length;
            }
            const last=nodes.at(-1);
            return [last,last?.data.length||0];
          };
          const [startNode,startOffset]=boundary(start);
          const [endNode,endOffset]=boundary(end);
          const first=document.createRange();
          first.setStart(startNode,startOffset); first.setEnd(startNode,startOffset+1);
          const line=document.createRange();
          line.setStart(startNode,startOffset); line.setEnd(endNode,endOffset);
          return {
            top:first.getBoundingClientRect().top-sc.getBoundingClientRect().top,
            rows:line.getClientRects().length,
            width:sc.clientWidth,
            lineText:text.slice(start,end),
            colWidth:document.querySelector('.col')?.getBoundingClientRect().width ?? -1
          };
        })()
        """
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        var others: [MarkdownPanel] = []
        defer { panel.close(); others.forEach { $0.close() } }
        let host = UUID()
        panel.setRendererVisible(true, hostID: host)
        var first: MarkdownWebRenderer? = panel.ensureRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: sourceMode ? 1000 : 460, height: sourceMode ? 800 : 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var hosted: NSView? = sourceMode ? first!.webView : NSHostingView(rootView: MarkdownWebContent(panel: panel, isFocused: false))
        window.contentView = hosted
        defer { window.contentView = nil; window.close() }
        await rendered(first!, revision: 1)
        _ = try await call(first!, "setSourceMode", arguments: [sourceMode])
        _ = try await call(first!, "find", arguments: [findQuery])
        _ = try await call(first!, "scrollToLine", arguments: [targetLine, 7.25])
        let beforeValue = try await call(first!, "visible")
        let before = try XCTUnwrap(beforeValue as? [String: Any])
        let position = try XCTUnwrap(MarkdownReadingPosition(state: before))
        XCTAssertGreaterThan(position.line, 1)
        XCTAssertGreaterThan(position.offset, 0, "Approved offset bridge must be present")
        XCTAssertEqual(position.sourceMode, sourceMode)
        XCTAssertEqual(position.findQuery, findQuery)
        if multiline {
            let visibleLines = try XCTUnwrap(before["lines"] as? [String: Any])
            XCTAssertEqual(visibleLines["first"] as? Int, targetLine, "visible().lines.first must be the selected interior source line")
            XCTAssertEqual(position.line, targetLine)
            XCTAssertEqual(position.offset, 7.25, accuracy: 1)
            let geometryValue = try await evaluate(first!, targetTextRowProbe)
            let geometry = try XCTUnwrap(geometryValue as? [String: Any])
            XCTAssertGreaterThan(geometry["rows"] as? Int ?? 0, 1, "Each source line must soft-wrap in the 460 px reader: \(geometry)")
            XCTAssertEqual(try XCTUnwrap(geometry["top"] as? Double), -position.offset, accuracy: 1,
                           "The interior line's text row must sit at the requested offset")
        }
        let evicted = expectation(description: "oldest hidden reader evicted")
        let token = MarkdownRendererCache.shared.evictions.first(where: { $0 == panel.id }).sink { _ in evicted.fulfill() }
        let hidden = expectation(description: "last native host dismantled")
        let visibilityToken = MarkdownRendererCache.shared.visibilityChanges.first(where: {
            $0 == panel.id && !panel.isRendererVisible
        }).sink { _ in hidden.fulfill() }
        window.contentView = nil
        hosted = nil
        panel.setRendererVisible(false, hostID: host)
        await fulfillment(of: [hidden], timeout: 10)
        withExtendedLifetime(visibilityToken) {}
        if !sourceMode {
            // SwiftUI dismantling can zero the retained native view. Capturing
            // that reflowed page must not replace the operator's reading anchor.
            first!.webView.frame = .zero
        }
        for _ in 0..<5 {
            let other = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
            others.append(other)
            _ = other.ensureRenderer()
        }
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
        hosted = sourceMode ? recreated.webView : NSHostingView(rootView: MarkdownWebContent(panel: panel, isFocused: false))
        window.contentView = hosted
        await rendered(recreated, revision: 2)
        let afterValue = try await call(recreated, "visible")
        let after = try XCTUnwrap(afterValue as? [String: Any])
        let restored = try XCTUnwrap(MarkdownReadingPosition(state: after))
        XCTAssertEqual(restored.line, position.line)
        XCTAssertEqual(restored.offset, position.offset, accuracy: 1)
        XCTAssertEqual(restored.sourceMode, position.sourceMode)
        XCTAssertEqual(restored.findQuery, position.findQuery)
        if multiline {
            let restoredLines = try XCTUnwrap(after["lines"] as? [String: Any])
            XCTAssertEqual(restoredLines["first"] as? Int, targetLine, "The restored visible().lines.first must remain the interior source line")
            XCTAssertEqual(restored.line, targetLine)
            let geometryValue = try await evaluate(recreated, targetTextRowProbe)
            let geometry = try XCTUnwrap(geometryValue as? [String: Any])
            XCTAssertGreaterThan(geometry["rows"] as? Int ?? 0, 1, "The restored paragraph must remain soft-wrapped: \(geometry)")
            XCTAssertEqual(try XCTUnwrap(geometry["top"] as? Double), -restored.offset, accuracy: 1,
                           "The restored interior text row must sit at the captured offset")
        }
        XCTAssertTrue(panel.content.contains("Latest content while evicted."))
        XCTAssertEqual(recreated.webView.pageZoom, 1)
    }

    func testHeldVisibleQueryPinsRendererUntilTheQueryFinishes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-query-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reader.md")
        try "# Reader\n\nA stable paragraph.\n".write(to: path, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        var others: [MarkdownPanel] = []
        defer {
            panel.close()
            others.forEach { $0.close() }
        }
        let renderer = panel.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)

        let userContentController = renderer.webView.configuration.userContentController
        let scriptProbe = MarkdownWebScriptMessageProbe()
        userContentController.add(scriptProbe, name: "c11mdTestProbe")
        defer { userContentController.removeScriptMessageHandler(forName: "c11mdTestProbe") }
        let queryEntered = expectation(description: "held visible query entered the page bridge")
        scriptProbe.onMessage = { body in
            guard body["type"] as? String == "visible-entered", body["call"] as? Int == 1 else { return }
            queryEntered.fulfill()
        }
        try await installVisibleGate(renderer, heldCalls: [1])

        let queryFinished = expectation(description: "held visible query completed")
        var queryResult: Result<Any, Error>?
        renderer.call("visible") { result in
            queryResult = result
            queryFinished.fulfill()
        }
        await fulfillment(of: [queryEntered], timeout: 10)
        XCTAssertTrue(renderer.hasQueriesInFlight, "The bridge promise must still be held while cache pressure is applied")

        let readyOther = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        others.append(readyOther)
        let readyOtherRenderer = readyOther.ensureRenderer()
        await rendered(readyOtherRenderer, revision: 1)
        for _ in 0..<4 {
            others.append(MarkdownPanel(workspaceId: UUID(), filePath: path.path))
        }

        let otherEvicted = expectation(description: "the cache evicted another eligible renderer")
        let otherIDs = Set(others.map(\.id))
        var observedOtherEviction = false
        let otherEvictionToken = MarkdownRendererCache.shared.evictions.sink { id in
            guard otherIDs.contains(id), !observedOtherEviction else { return }
            observedOtherEviction = true
            otherEvicted.fulfill()
        }
        for other in others.dropFirst() {
            // These fillers count toward the bounded cache but cannot race the
            // one ready peer for the deterministic eviction signal.
            other.ensureRenderer().webView.stopLoading()
        }
        await fulfillment(of: [otherEvicted], timeout: 30)
        XCTAssertTrue(panel.renderer === renderer, "The held query must keep its renderer resident while the cache evicts a peer")
        XCTAssertTrue(renderer.hasQueriesInFlight)

        let heldRendererEvicted = expectation(description: "the held renderer became eligible after its query finished")
        let heldEvictionToken = MarkdownRendererCache.shared.evictions
            .filter { $0 == panel.id }
            .sink { _ in heldRendererEvicted.fulfill() }
        let queryReleased = try await evaluate(renderer, "window.__releaseMarkdownVisibleCall(1)") as? Bool
        XCTAssertEqual(queryReleased, true)
        await fulfillment(of: [queryFinished], timeout: 10)
        _ = try XCTUnwrap(queryResult).get()

        // Reassert pressure if the peer eviction brought the cache exactly
        // back to capacity. The held renderer is oldest and must now leave.
        let finalFiller = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        others.append(finalFiller)
        let finalFillerRenderer = finalFiller.ensureRenderer()
        await rendered(finalFillerRenderer, revision: 1)
        await fulfillment(of: [heldRendererEvicted], timeout: 30)
        XCTAssertNil(panel.renderer)
        withExtendedLifetime((otherEvictionToken, heldEvictionToken)) {}
    }

    func testCacheDiscardsCaptureCrossedByNativeQueryEpoch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-capture-epoch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reader.md")
        try "# Reader\n\nA stable paragraph.\n".write(to: path, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        var fillers: [MarkdownPanel] = []
        defer {
            panel.close()
            fillers.forEach { $0.close() }
        }
        let renderer = panel.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)

        let userContentController = renderer.webView.configuration.userContentController
        let scriptProbe = MarkdownWebScriptMessageProbe()
        userContentController.add(scriptProbe, name: "c11mdTestProbe")
        defer { userContentController.removeScriptMessageHandler(forName: "c11mdTestProbe") }
        let firstCaptureEntered = expectation(description: "cache capture entered its held bridge call")
        let recaptureEntered = expectation(description: "stale capture returned and cache began a fresh round")
        scriptProbe.onMessage = { body in
            guard body["type"] as? String == "visible-entered" else { return }
            switch body["call"] as? Int {
            case 1: firstCaptureEntered.fulfill()
            case 3: recaptureEntered.fulfill()
            default: break
            }
        }
        try await installVisibleGate(renderer, heldCalls: [1, 3])

        // Four stopped renderers make this oldest hidden renderer the sole
        // eligible candidate without allowing filler captures to race it.
        for _ in 0..<4 {
            let filler = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
            fillers.append(filler)
            filler.ensureRenderer().webView.stopLoading()
        }
        await fulfillment(of: [firstCaptureEntered], timeout: 10)

        let queryValue = try await call(renderer, "visible")
        XCTAssertNotNil(queryValue as? [String: Any])
        XCTAssertFalse(renderer.hasQueriesInFlight)
        let firstCaptureReleased = try await evaluate(renderer, "window.__releaseMarkdownVisibleCall(1)") as? Bool
        XCTAssertEqual(firstCaptureReleased, true)

        await fulfillment(of: [recaptureEntered], timeout: 10)
        XCTAssertTrue(panel.renderer === renderer, "The first capture crossed a newer native query and must not evict")

        let evicted = expectation(description: "the fresh capture round may evict the still-oldest hidden renderer")
        let token = MarkdownRendererCache.shared.evictions
            .filter { $0 == panel.id }
            .sink { _ in evicted.fulfill() }
        let recaptureReleased = try await evaluate(renderer, "window.__releaseMarkdownVisibleCall(3)") as? Bool
        XCTAssertEqual(recaptureReleased, true)
        await fulfillment(of: [evicted], timeout: 30)
        XCTAssertNil(panel.renderer)
        withExtendedLifetime(token) {}
    }

    func testRealWebKitRejectsNavigationPopupAndZoomShortcut() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-web-navigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reader.md")
        try "# Reader\n\nStable page marker.\n".write(to: path, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        defer { panel.close() }
        let renderer = panel.ensureRenderer()
        // Exercise the native createWebViewWith refusal even though normal
        // production policy also disables script-created windows.
        renderer.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)

        let navigationProbe = MarkdownWebRendererDelegateProbe(renderer: renderer)
        renderer.webView.navigationDelegate = navigationProbe
        renderer.webView.uiDelegate = navigationProbe

        let renderedToken = renderer.$renderedRevision.dropFirst().sink { _ in
            navigationProbe.renderedEventsAfterStart += 1
        }
        let initialState = try await call(renderer, "visible") as? [String: Any]
        let revision = try XCTUnwrap(initialState?["revision"] as? Int)
        _ = try await evaluate(renderer, "window.__markdownNavigationMarker = 'stable'; true")

        let c11Decision = expectation(description: "c11md navigation was canceled")
        let c11DecisionToken = navigationProbe.decisions.first(where: {
            $0.0 == "c11md://bundle/index.html?x"
        }).sink { _, policy in
            XCTAssertEqual(policy, .cancel)
            c11Decision.fulfill()
        }
        _ = try await evaluate(renderer, "location.assign('c11md://bundle/index.html?x'); true")
        await fulfillment(of: [c11Decision], timeout: 10)
        try await assertNavigationMarker(renderer, revision: revision)

        let httpsDecision = expectation(description: "HTTPS navigation was canceled")
        let httpsDecisionToken = navigationProbe.decisions.first(where: {
            $0.0 == "https://example.invalid/"
        }).sink { _, policy in
            XCTAssertEqual(policy, .cancel)
            httpsDecision.fulfill()
        }
        _ = try await evaluate(renderer, "location.assign('https://example.invalid/'); true")
        await fulfillment(of: [httpsDecision], timeout: 10)
        try await assertNavigationMarker(renderer, revision: revision)

        let popupCreated = expectation(description: "window.open reached the native new-window refusal")
        let popupToken = navigationProbe.newWindows.first(where: {
            $0 == "c11md://bundle/index.html"
        }).sink { _ in popupCreated.fulfill() }
        _ = try await evaluate(renderer, "window.__markdownPopupReturnedNull = window.open('c11md://bundle/index.html') === null; true")
        await fulfillment(of: [popupCreated], timeout: 10)
        let popupWasBlocked = try await evaluate(renderer, "window.__markdownPopupReturnedNull") as? Bool
        XCTAssertEqual(popupWasBlocked, true)
        XCTAssertEqual(navigationProbe.returnedWebViewCount, 0, "The native delegate must not create a second WebView")
        try await assertNavigationMarker(renderer, revision: revision)

        let oldMainMenu = NSApp.mainMenu
        let appDelegate = AppDelegate.shared
        let oldWorkspaceManager = appDelegate?.workspaceManager
        NSApp.mainMenu = nil
        appDelegate?.workspaceManager = nil
        defer {
            NSApp.mainMenu = oldMainMenu
            appDelegate?.workspaceManager = oldWorkspaceManager
            renderer.webView.navigationDelegate = renderer
            renderer.webView.uiDelegate = renderer
        }
        let zoomEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "=",
            charactersIgnoringModifiers: "=",
            isARepeat: false,
            keyCode: 24
        ))
        renderer.webView.allowsPanelFocus = true
        XCTAssertTrue(window.makeFirstResponder(renderer.webView), "The synthetic shortcut must run through the real WebKit responder")
        XCTAssertTrue(window.firstResponder === renderer.webView)
        XCTAssertFalse(renderer.webView.performKeyEquivalent(with: zoomEvent))
        XCTAssertEqual(renderer.webView.pageZoom, 1)
        XCTAssertEqual(renderer.renderedRevision, 1)
        XCTAssertEqual(navigationProbe.renderedEventsAfterStart, 0, "Rejected navigation must not render a new entry")
        withExtendedLifetime((renderedToken, c11DecisionToken, httpsDecisionToken, popupToken)) {}
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

    func testClosingRendererNotifiesItsStateObservers() async throws {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }
        let renderer = panel.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)

        let ended = expectation(description: "renderer close ends its state observer")
        let subscription = try XCTUnwrap(renderer.observeState { state in
            if state == nil { ended.fulfill() }
        })
        XCTAssertFalse(subscription.state.isEmpty)
        renderer.close()
        await fulfillment(of: [ended], timeout: 2)
    }

    func testVisibleWatchCreatesReaderForNeverMountedPanelOverSocket() async throws {
        _ = NSApplication.shared
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let selectedWorkspaceBefore = manager.selectedWorkspaceId
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-watch-socket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            workspace.teardownAllPanels()
            try? FileManager.default.removeItem(at: folder)
        }
        let path = folder.appendingPathComponent("reader.md")
        try "# Socket reader\n\n## Installation\n\nA stable paragraph.\n".write(to: path, atomically: true, encoding: .utf8)
        let panel = try XCTUnwrap(workspace.newMarkdownPanel(inPane: pane, filePath: path.path, focus: false))
        XCTAssertNil(panel.renderer, "the target panel has never had a native reader")

        let controller = TerminalController.makeForTesting()
        let priorManager = controller.workspaceManager
        controller.workspaceManager = manager
        defer { controller.workspaceManager = priorManager }

        final class ControllerBox: @unchecked Sendable {
            let value: TerminalController
            init(_ value: TerminalController) { self.value = value }
        }
        let controllerBox = ControllerBox(controller)
        final class ContinueFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var running = true
            var shouldContinue: Bool {
                lock.lock(); defer { lock.unlock() }
                return running
            }
            func stop() {
                lock.lock(); running = false; lock.unlock()
            }
        }
        let continueFlag = ContinueFlag()
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let client = sockets[0]
        let server = sockets[1]
        let serverTask = Task.detached {
            TerminalController.serveCommandLines(
                socket: server,
                shouldContinue: { continueFlag.shouldContinue },
                respond: { _ in "{\"ok\":false}\n" },
                stream: { command, streamSocket, shouldContinue in
                    guard let data = command.data(using: .utf8),
                          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let params = request["params"] as? [String: Any] else { return false }
                    controllerBox.value.v2StreamMarkdownVisible(
                        id: request["id"],
                        params: params,
                        socket: streamSocket,
                        shouldContinue: shouldContinue
                    )
                    return true
                }
            )
        }
        let request: [String: Any] = [
            "id": "watch-never-mounted",
            "method": "markdown.visible",
            "params": ["surface_id": panel.id.uuidString, "workspace_id": workspace.id.uuidString, "watch": true]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let requestBytes = data + Data([0x0A])
        let written = requestBytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        XCTAssertEqual(written, requestBytes.count)

        let responseLine = await Task.detached { () -> String? in
            var response: [UInt8] = []
            var byte: UInt8 = 0
            while read(client, &byte, 1) == 1 {
                if byte == 0x0A { return String(decoding: response, as: UTF8.self) }
                response.append(byte)
            }
            return nil
        }.value
        let responseData = try XCTUnwrap(responseLine?.data(using: .utf8))
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        continueFlag.stop()
        await serverTask.value
        close(client)
        close(server)
        sockets = [-1, -1]

        XCTAssertEqual(envelope["id"] as? String, "watch-never-mounted")
        XCTAssertEqual(envelope["ok"] as? Bool, true, "socket watch should initialize an unmounted reader")
        XCTAssertNotNil(panel.renderer)
        XCTAssertFalse(panel.isRendererVisible, "an agent-created reader remains unmounted and hidden")
        XCTAssertEqual(manager.selectedWorkspaceId, selectedWorkspaceBefore, "reader creation must not select a workspace")
    }

    func testMarkdownSocketRejectsUnresolvedPanelRefsWithoutFallingBack() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["markdown.fontScale.lastUsed", "markdown.theme.lastUsed", "markdown.typeface.lastUsed"]
        var savedDefaults: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { savedDefaults[key] = value }
        }
        defer {
            for key in keys {
                if let value = savedDefaults[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(1.4, forKey: "markdown.fontScale.lastUsed")
        defaults.set("dark", forKey: "markdown.theme.lastUsed")
        defaults.set("serif", forKey: "markdown.typeface.lastUsed")

        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let selectedWorkspaceBefore = manager.selectedWorkspaceId
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-invalid-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            workspace.teardownAllPanels()
            try? FileManager.default.removeItem(at: folder)
        }
        let path = folder.appendingPathComponent("reader.md")
        try "# Focused reader\n\n## Install\n\nA.\n\n## Installation\n\nB.\n\n## Installing the App\n\nC.\n".write(to: path, atomically: true, encoding: .utf8)
        let panel = try XCTUnwrap(workspace.newMarkdownPanel(inPane: pane, filePath: path.path, focus: true))
        XCTAssertEqual(workspace.focusedPanelId, panel.id)
        XCTAssertEqual(panel.theme, "dark")
        XCTAssertEqual(panel.typeface, "serif")
        XCTAssertEqual(panel.fontScale, 1.4)
        XCTAssertNil(panel.renderer)
        let panelCountBefore = workspace.panels.count

        let controller = TerminalController.makeForTesting()
        let priorManager = controller.workspaceManager
        controller.workspaceManager = manager
        defer { controller.workspaceManager = priorManager }

        final class ControllerBox: @unchecked Sendable {
            let value: TerminalController
            init(_ value: TerminalController) { self.value = value }
        }
        final class ContinueFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var running = true
            var shouldContinue: Bool {
                lock.lock(); defer { lock.unlock() }
                return running
            }
            func stop() {
                lock.lock(); running = false; lock.unlock()
            }
        }
        let controllerBox = ControllerBox(controller)

        func send(_ method: String, params: [String: Any]) async throws -> [String: Any] {
            let continueFlag = ContinueFlag()
            var sockets: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
            let client = sockets[0]
            let server = sockets[1]
            let serverTask = Task.detached {
                TerminalController.serveCommandLines(
                    socket: server,
                    shouldContinue: { continueFlag.shouldContinue },
                    respond: { command in
                        guard let data = command.data(using: .utf8),
                              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let method = request["method"] as? String,
                              let params = request["params"] as? [String: Any] else { return "{\"ok\":false}" }
                        let id = request["id"]
                        if method == "markdown.open" || method == "markdown.get_content" {
                            return DispatchQueue.main.sync {
                                MainActor.assumeIsolated {
                                    controllerBox.value.v2DispatchMarkdownFeedback(method, id: id, params: params)
                                }
                            }
                        }
                        return controllerBox.value.v2Result(
                            id: id,
                            controllerBox.value.v2DispatchMarkdownWorker(method, params: params)
                        )
                    },
                    stream: { command, streamSocket, shouldContinue in
                        guard let data = command.data(using: .utf8),
                              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let method = request["method"] as? String,
                              method == "markdown.visible",
                              let params = request["params"] as? [String: Any],
                              params["watch"] as? Bool == true else { return false }
                        controllerBox.value.v2StreamMarkdownVisible(
                            id: request["id"], params: params, socket: streamSocket,
                            shouldContinue: shouldContinue
                        )
                        return true
                    }
                )
            }
            let request: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
            let data = try JSONSerialization.data(withJSONObject: request)
            let bytes = data + Data([0x0A])
            let written = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            XCTAssertEqual(written, bytes.count)
            _ = shutdown(client, SHUT_WR)
            let responseLine = await Task.detached { () -> String? in
                var response: [UInt8] = []
                var byte: UInt8 = 0
                while read(client, &byte, 1) == 1 {
                    if byte == 0x0A { return String(decoding: response, as: UTF8.self) }
                    response.append(byte)
                }
                return response.isEmpty ? nil : String(decoding: response, as: UTF8.self)
            }.value
            let responseData = try XCTUnwrap(responseLine?.data(using: .utf8))
            let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
            continueFlag.stop()
            await serverTask.value
            close(client)
            close(server)
            sockets = [-1, -1]
            return envelope
        }

        func scoped(_ panelRef: String) -> [String: Any] {
            ["surface_id": panelRef, "workspace_id": workspace.id.uuidString]
        }
        func assertNotFound(_ envelope: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(envelope["ok"] as? Bool, false, file: file, line: line)
            XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "not_found", file: file, line: line)
        }

        let stalePanelRef = "panel:99999"
        assertNotFound(try await send("markdown.theme", params: scoped(stalePanelRef).merging(["action": "set", "name": "light"]) { _, new in new }))
        assertNotFound(try await send("markdown.typeface", params: scoped(stalePanelRef).merging(["action": "set", "name": "sans"]) { _, new in new }))
        assertNotFound(try await send("markdown.font", params: scoped(stalePanelRef).merging(["scale": 2.2]) { _, new in new }))
        assertNotFound(try await send("markdown.scroll", params: scoped(stalePanelRef).merging(["heading": "Installation"]) { _, new in new }))
        assertNotFound(try await send("markdown.visible", params: scoped(stalePanelRef)))
        assertNotFound(try await send("markdown.visible", params: scoped(stalePanelRef).merging(["watch": true]) { _, new in new }))
        assertNotFound(try await send("markdown.theme", params: scoped(UUID().uuidString).merging(["action": "set", "name": "light"]) { _, new in new }))
        assertNotFound(try await send("markdown.theme", params: scoped(pane.id.uuidString).merging(["action": "set", "name": "light"]) { _, new in new }))
        let unsupportedTheme = try await send(
            "markdown.theme",
            params: scoped(panel.id.uuidString).merging(["action": "set", "name": "sepia"]) { _, new in new }
        )
        XCTAssertEqual(unsupportedTheme["ok"] as? Bool, false)
        XCTAssertEqual((unsupportedTheme["error"] as? [String: Any])?["code"] as? String, "invalid_params")
        assertNotFound(try await send("markdown.open", params: scoped(stalePanelRef).merging(["path": path.path]) { _, new in new }))
        assertNotFound(try await send("markdown.navigate", params: scoped(stalePanelRef).merging(["path": path.path]) { _, new in new }))
        assertNotFound(try await send("markdown.history", params: scoped(stalePanelRef)))
        assertNotFound(try await send("markdown.links", params: scoped(stalePanelRef).merging(["broken": true]) { _, new in new }))
        assertNotFound(try await send("markdown.get_content", params: scoped(stalePanelRef)))

        XCTAssertNil(panel.renderer, "unresolved refs must return before creating a hidden reader")
        let ambiguousHeading = try await send(
            "markdown.scroll",
            params: scoped(panel.id.uuidString).merging(["heading": "Inst"]) { _, new in new }
        )
        XCTAssertEqual(ambiguousHeading["ok"] as? Bool, false)
        XCTAssertEqual((ambiguousHeading["error"] as? [String: Any])?["code"] as? String, "ambiguous")
        XCTAssertEqual(((ambiguousHeading["error"] as? [String: Any])?["data"] as? [String: Any])?["total"] as? Int, 3)

        XCTAssertEqual(panel.theme, "dark")
        XCTAssertEqual(panel.typeface, "serif")
        XCTAssertEqual(panel.fontScale, 1.4)
        XCTAssertEqual(defaults.string(forKey: "markdown.theme.lastUsed"), "dark")
        XCTAssertEqual(defaults.string(forKey: "markdown.typeface.lastUsed"), "serif")
        XCTAssertEqual(defaults.double(forKey: "markdown.fontScale.lastUsed"), 1.4)
        XCTAssertNotNil(panel.renderer, "the valid ambiguous scroll creates a hidden reader")
        XCTAssertEqual(workspace.panels.count, panelCountBefore, "markdown.open must not split from the focused panel")
        XCTAssertEqual(manager.selectedWorkspaceId, selectedWorkspaceBefore)
    }

    /// PM-359-f probe (round 3): record every stage of a chrome appearance flip.
    func testProbeAppearanceFlipReachesMountedSystemThemeReader() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-appearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reader.md")
        try "# Reader\n\nA stable paragraph.\n".write(to: path, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        defer { panel.close() }
        panel.applyRestoredPresentation(SessionMarkdownPanelSnapshot(fontScale: 1, theme: "system", typeface: "theme", outlineOpen: false))
        let oldAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = oldAppearance }
        let runtime = AreaInteractionRuntime()
        let host = NSHostingView(rootView: MarkdownPanelView(
            panel: panel, isFocused: false, isVisibleInUI: true, portalPriority: 0,
            onRequestPanelFocus: {}, paneInteractionRuntime: runtime))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        var created: MarkdownWebRenderer?
        for _ in 0..<200 where created == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            created = panel.renderer
        }
        let renderer = try XCTUnwrap(created, "The SwiftUI host must create the renderer")
        await rendered(renderer, revision: 1)
        func resolvedTheme() async throws -> String {
            let now = try await call(renderer, "visible") as? [String: Any]
            return (now?["theme"] as? [String: Any])?["resolved"] as? String ?? "?"
        }
        func effective() -> String { renderer.webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? "?" }
        func settle(_ seconds: Double, until: () async throws -> Bool) async throws {
            for _ in 0..<Int(seconds * 20) { try await Task.sleep(nanoseconds: 50_000_000); if try await until() { return } }
        }
        var log: [String] = []
        log.append("initial: effective=\(effective()) resolved=\(try await resolvedTheme())")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await settle(4) { try await resolvedTheme() == "dark" }
        log.append("after NSApp.appearance=dark + 4s: effective=\(effective()) resolved=\(try await resolvedTheme())")
        let stage1 = try await resolvedTheme()
        ThemeManager.shared.objectWillChange.send()
        try await settle(2) { try await resolvedTheme() == "dark" }
        log.append("after ThemeManager publish + 2s: effective=\(effective()) resolved=\(try await resolvedTheme())")
        let stage2 = try await resolvedTheme()
        host.frame = NSRect(x: 0, y: 0, width: 790, height: 600)
        host.layoutSubtreeIfNeeded()
        try await settle(2) { try await resolvedTheme() == "dark" }
        log.append("after host resize + 2s: effective=\(effective()) resolved=\(try await resolvedTheme())")
        let stage3 = try await resolvedTheme()
        renderer.synchronize()
        try await settle(2) { try await resolvedTheme() == "dark" }
        log.append("after manual synchronize + 2s: effective=\(effective()) resolved=\(try await resolvedTheme())")
        let stage4 = try await resolvedTheme()
        XCTAssertTrue(panel.renderer === renderer)
        XCTAssertEqual(stage4, "dark", "PROBE LOG: " + log.joined(separator: " | "))
        XCTAssertEqual(stage1, "dark", "appearance flip alone did not reach the reader. PROBE LOG: " + log.joined(separator: " | "))
        XCTAssertEqual(stage2, "dark", "ThemeManager publish did not reach the reader. PROBE LOG: " + log.joined(separator: " | "))
        XCTAssertEqual(stage3, "dark", "host relayout did not reach the reader. PROBE LOG: " + log.joined(separator: " | "))
    }


    private func installVisibleGate(_ renderer: MarkdownWebRenderer, heldCalls: [Int]) async throws {
        let installed = try await evaluateAsync(renderer, #"""
            const original = window.c11md;
            const heldCalls = new Set(heldCallsArgument);
            window.__markdownVisibleCalls = 0;
            window.__markdownVisibleReleases = Object.create(null);
            window.c11md = Object.freeze({
              ...original,
              visible: async (...args) => {
                const call = ++window.__markdownVisibleCalls;
                window.webkit.messageHandlers.c11mdTestProbe.postMessage({type: 'visible-entered', call});
                if (heldCalls.has(call)) {
                  await new Promise(resolve => { window.__markdownVisibleReleases[call] = resolve; });
                }
                return original.visible(...args);
              }
            });
            window.__releaseMarkdownVisibleCall = call => {
              const release = window.__markdownVisibleReleases[call];
              if (typeof release !== 'function') return false;
              delete window.__markdownVisibleReleases[call];
              release();
              return true;
            };
            return Object.getOwnPropertyDescriptor(window, 'c11md').writable === true;
            """#, arguments: ["heldCallsArgument": heldCalls])
        XCTAssertEqual(installed as? Bool, true, "The bridge object must be writable for the held-promise witness")
    }

    private func assertNavigationMarker(_ renderer: MarkdownWebRenderer, revision: Int) async throws {
        let value = try await evaluate(renderer, "({marker: window.__markdownNavigationMarker, revision: window.c11md.visible().revision})")
        let state = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(state["marker"] as? String, "stable")
        XCTAssertEqual(state["revision"] as? Int, revision)
        XCTAssertEqual(renderer.renderedRevision, revision)
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

    private func evaluateAsync(
        _ renderer: MarkdownWebRenderer,
        _ script: String,
        arguments: [String: Any] = [:]
    ) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            renderer.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) {
                continuation.resume(with: $0)
            }
        }
    }
}

@MainActor
private final class MarkdownWebScriptMessageProbe: NSObject, WKScriptMessageHandler {
    var onMessage: (([String: Any]) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        onMessage?(body)
    }
}

@MainActor
private final class MarkdownWebRendererDelegateProbe: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var renderer: MarkdownWebRenderer?
    let decisions = PassthroughSubject<(String, WKNavigationActionPolicy), Never>()
    let newWindows = PassthroughSubject<String, Never>()
    private(set) var returnedWebViewCount = 0
    var renderedEventsAfterStart = 0

    init(renderer: MarkdownWebRenderer) {
        self.renderer = renderer
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let renderer else {
            decisionHandler(.cancel)
            return
        }
        renderer.webView(webView, decidePolicyFor: navigationAction) { [weak self] policy in
            self?.decisions.send((navigationAction.request.url?.absoluteString ?? "", policy))
            decisionHandler(policy)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        renderer?.webView(webView, didFinish: navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        renderer?.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        renderer?.webView(webView, didFail: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        renderer?.webViewWebContentProcessDidTerminate(webView)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        newWindows.send(navigationAction.request.url?.absoluteString ?? "")
        let result = renderer?.webView(webView, createWebViewWith: configuration, for: navigationAction, windowFeatures: windowFeatures)
        if result != nil { returnedWebViewCount += 1 }
        return result
    }
}

// Post-merge review probes: real file watcher, bundle, cache and non-visible AppKit host.
extension MarkdownWebRendererTests {
    func testPostMergeRetainedReloadKeepsContentWhenLinesAreInsertedAbove() async throws {
        try await postMergeInsertedLines(evict: false)
    }

    func testPostMergeEvictedReloadKeepsContentWhenLinesAreInsertedAbove() async throws {
        try await postMergeInsertedLines(evict: true)
    }

    // SYNTH PROBE: deletion above the anchor while evicted.
    func testSynthEvictedReloadKeepsContentWhenLinesAreDeletedAbove() async throws {
        try await postMergeInsertedLines(evict: true, deleteAbove: true)
    }

    private func postMergeInsertedLines(evict: Bool, deleteAbove: Bool = false) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-pm-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reader.md")
        let text = "# Reader\n\n" + (1...80).map { "## Section \($0)\n\nParagraph \($0).\n\n" }.joined()
        try text.write(to: path, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        panel.applyRestoredPresentation(SessionMarkdownPanelSnapshot(fontScale: 1, theme: "light", typeface: "sans", outlineOpen: false))
        var others: [MarkdownPanel] = []
        defer { panel.close(); others.forEach { $0.close() } }
        let hostID = UUID()
        panel.setRendererVisible(true, hostID: hostID)
        var renderer = panel.ensureRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)
        _ = try await call(renderer, "scrollToHeading", arguments: ["Section 40"])
        let beforeValue = try await call(renderer, "visible")
        let before = try XCTUnwrap(beforeValue as? [String: Any])
        let headingBefore = try XCTUnwrap((before["heading"] as? [String: Any])?["text"] as? String)
        let yBeforeValue = try await evaluate(renderer, "document.getElementById('c11md-h-section-40').getBoundingClientRect().top")
        let yBefore = try XCTUnwrap(yBeforeValue as? Double)
        XCTAssertEqual(headingBefore, "Section 40")

        if evict {
            let evicted = expectation(description: "postmerge target evicted")
            let token = MarkdownRendererCache.shared.evictions.first(where: { $0 == panel.id }).sink { _ in evicted.fulfill() }
            panel.setRendererVisible(false, hostID: hostID)
            window.contentView = nil
            for _ in 0..<5 {
                let other = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
                others.append(other)
                _ = other.ensureRenderer()
            }
            await fulfillment(of: [evicted], timeout: 30)
            withExtendedLifetime(token) {}
            XCTAssertNil(panel.renderer)
        }

        let inserted = (1...12).map { "## Added \($0)\n\nNew paragraph \($0).\n\n" }.joined()
        let deletedPrefix = (1...12).map { "## Section \($0)\n\nParagraph \($0).\n\n" }.joined()
        let changed = deleteAbove ? text.replacingOccurrences(of: deletedPrefix, with: "") : inserted + text
        if deleteAbove { XCTAssertNotEqual(changed, text) }
        let reloaded = expectation(description: "postmerge watcher applied inserted text")
        let contentToken = panel.$content.first(where: { $0 == changed }).sink { _ in reloaded.fulfill() }
        try changed.write(to: path, atomically: true, encoding: .utf8)
        await fulfillment(of: [reloaded], timeout: 10)
        withExtendedLifetime(contentToken) {}
        if evict {
            XCTAssertNil(panel.renderer)
            panel.setRendererVisible(true, hostID: hostID)
            renderer = panel.ensureRenderer()
            window.contentView = renderer.webView
            await rendered(renderer, revision: 2)
        } else {
            await rendered(renderer, revision: 2)
        }
        let afterValue = try await call(renderer, "visible")
        let after = try XCTUnwrap(afterValue as? [String: Any])
        let yAfterValue = try await evaluate(renderer, "document.getElementById('c11md-h-section-40').getBoundingClientRect().top")
        let yAfter = try XCTUnwrap(yAfterValue as? Double)
        let headingAfter = (after["heading"] as? [String: Any])?["text"] as? String
        print("POSTMERGE_INSERT evict=\(evict) before=\(headingBefore) after=\(headingAfter ?? "nil") beforeLines=\(String(describing: before["lines"])) afterLines=\(String(describing: after["lines"])) beforeY=\(yBefore) afterY=\(yAfter)")
        XCTAssertEqual(headingAfter, headingBefore, "Inserting earlier sections while evicted must preserve the content being read")
        XCTAssertEqual(yAfter, yBefore, accuracy: 1, "Unchanged Section 40 must stay in the same viewport position")
    }
}

// Review 1 (C11-362) probes. Scratch copy only.
extension MarkdownWebRendererTests {
    private func reviewSend(_ controller: TerminalController, _ method: String, params: [String: Any]) async throws -> [String: Any] {
        final class Box: @unchecked Sendable { let value: TerminalController; init(_ v: TerminalController) { value = v } }
        final class Flag: @unchecked Sendable {
            private let lock = NSLock(); private var running = true
            var shouldContinue: Bool { lock.lock(); defer { lock.unlock() }; return running }
            func stop() { lock.lock(); running = false; lock.unlock() }
        }
        let box = Box(controller), flag = Flag()
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let client = sockets[0], server = sockets[1]
        let serverTask = Task.detached {
            TerminalController.serveCommandLines(
                socket: server,
                shouldContinue: { flag.shouldContinue },
                respond: { command in
                    guard let data = command.data(using: .utf8),
                          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let method = request["method"] as? String,
                          let params = request["params"] as? [String: Any] else { return "{\"ok\":false}" }
                    return box.value.v2Result(id: request["id"], box.value.v2DispatchMarkdownWorker(method, params: params))
                },
                stream: { _, _, _ in false }
            )
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params]) + Data([0x0A])
        XCTAssertEqual(bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }, bytes.count)
        _ = shutdown(client, SHUT_WR)
        let line = await Task.detached { () -> String? in
            var response: [UInt8] = []; var byte: UInt8 = 0
            while read(client, &byte, 1) == 1 { if byte == 0x0A { break }; response.append(byte) }
            return response.isEmpty ? nil : String(decoding: response, as: UTF8.self)
        }.value
        flag.stop(); await serverTask.value; close(client); close(server)
        let lineData = try XCTUnwrap(line?.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: lineData) as? [String: Any])
    }

    func testMarkdownSocketNavigationKeepsFocusAndHiddenPanelRestoresFragment() async throws {
        _ = NSApplication.shared
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let selectedBefore = manager.selectedWorkspaceId
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-socket-navigation-\(UUID().uuidString)")
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { workspace.teardownAllPanels(); try? FileManager.default.removeItem(at: root) }
        let source = docs.appendingPathComponent("source.md")
        let target = docs.appendingPathComponent("target.md")
        try "# Source\n\n[ok](target.md#details)\n\n[bad](target.md#nope)\n\n[gone](missing.md)\n\n[large](large.md#unknown)\n\n[self](#source)\n\n[selfbad](#zzz)\n".write(to: source, atomically: true, encoding: .utf8)
        try ("# Target\n\n" + (1...40).map { "Filler \($0).\n\n" }.joined() + "## Details\n\nHere.\n\n" + (1...40).map { "Tail \($0).\n\n" }.joined()).write(to: target, atomically: true, encoding: .utf8)
        let large = docs.appendingPathComponent("large.md")
        var largeContent = Data("# Large\n\n".utf8)
        largeContent.append(Data(repeating: 0x61, count: 300 * 1024))
        try largeContent.write(to: large)
        let focused = try XCTUnwrap(workspace.newMarkdownPanel(inPane: pane, filePath: source.path, focus: true))
        let background = try XCTUnwrap(workspace.newMarkdownPanel(inPane: pane, filePath: source.path, focus: false))
        workspace.focusPanel(focused.id)
        let focusedBefore = workspace.focusedPanelId
        XCTAssertNil(background.renderer)
        let controller = TerminalController.makeForTesting()
        let prior = controller.workspaceManager
        controller.workspaceManager = manager
        defer { controller.workspaceManager = prior }
        let scope: [String: Any] = ["surface_id": background.id.uuidString, "workspace_id": workspace.id.uuidString]

        let relative = try await reviewSend(controller, "markdown.navigate", params: scope.merging(["path": "docs/target.md"]) { $1 })
        XCTAssertEqual((relative["error"] as? [String: Any])?["code"] as? String, "invalid_params", "relative raw path: \(relative)")
        let stale = try await reviewSend(controller, "markdown.navigate", params: ["surface_id": "panel:99999", "workspace_id": workspace.id.uuidString, "path": target.path])
        XCTAssertEqual((stale["error"] as? [String: Any])?["code"] as? String, "not_found", "stale ref: \(stale)")
        let staleHistory = try await reviewSend(controller, "markdown.history", params: ["surface_id": "panel:99999", "workspace_id": workspace.id.uuidString])
        XCTAssertEqual((staleHistory["error"] as? [String: Any])?["code"] as? String, "not_found", "stale history ref: \(staleHistory)")
        let staleLinks = try await reviewSend(controller, "markdown.links", params: ["surface_id": "panel:99999", "workspace_id": workspace.id.uuidString, "broken": true])
        XCTAssertEqual((staleLinks["error"] as? [String: Any])?["code"] as? String, "not_found", "stale links ref: \(staleLinks)")

        let nav = try await reviewSend(controller, "markdown.navigate", params: scope.merging(["path": target.path, "fragment": "details"]) { $1 })
        XCTAssertEqual(nav["ok"] as? Bool, true, "\(nav)")
        XCTAssertEqual((nav["result"] as? [String: Any])?["outcome"] as? String, "navigated", "\(nav)")
        XCTAssertEqual(background.filePath, target.path)
        XCTAssertEqual(workspace.focusedPanelId, focusedBefore, "navigate must not move panel focus")
        XCTAssertEqual(manager.selectedWorkspaceId, selectedBefore, "navigate must not select a workspace")
        XCTAssertNil(background.renderer, "navigating a never-shown panel stays model-only")

        let again = try await reviewSend(controller, "markdown.navigate", params: scope.merging(["path": target.path, "fragment": "details"]) { $1 })
        XCTAssertEqual((again["result"] as? [String: Any])?["outcome"] as? String, "navigated", "repeated fragment navigation should reapply: \(again)")

        let history = try await reviewSend(controller, "markdown.history", params: scope)
        let snapshot = try XCTUnwrap((history["result"] as? [String: Any])?["history"] as? [String: Any], "\(history)")
        XCTAssertEqual((snapshot["entries"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(background.renderer, "history answers from the model")

        // Recreate the hidden reader: the pending fragment must land.
        let renderer = background.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)
        let stateValue = try await call(renderer, "visible")
        let state = try XCTUnwrap(stateValue as? [String: Any])
        XCTAssertEqual((state["heading"] as? [String: Any])?["text"] as? String, "Details", "pending fragment after recreation: \(state["heading"] ?? "nil")")

        // links --broken from the focused source panel.
        let links = try await reviewSend(controller, "markdown.links", params: ["surface_id": focused.id.uuidString, "workspace_id": workspace.id.uuidString, "broken": true])
        let result = try XCTUnwrap(links["result"] as? [String: Any], "\(links)")
        XCTAssertNil(result["broken"], "links returns one canonical array")
        let broken = try XCTUnwrap(result["links"] as? [[String: Any]], "\(links)")
        XCTAssertEqual(Set(broken.compactMap { $0["href"] as? String }), ["target.md#nope", "missing.md", "#zzz"])
        XCTAssertEqual(Set(broken.compactMap { $0["reason"] as? String }), ["missing_fragment", "not_found"])
        XCTAssertEqual(result["truncated"] as? Bool, true, "large fragment targets are uninspected, not mislabeled broken")
        XCTAssertEqual(workspace.focusedPanelId, focusedBefore)
        XCTAssertEqual(manager.selectedWorkspaceId, selectedBefore)
    }

    func testMarkdownHistoryBackRestoresPositionLiveAndAfterEviction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-history-back-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.md")
        let target = root.appendingPathComponent("target.md")
        try ("# Source\n\n" + (1...80).map { "## S\($0)\n\nParagraph \($0).\n\n" }.joined()).write(to: source, atomically: true, encoding: .utf8)
        try "# Target\n\nShort.\n".write(to: target, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: source.path)
        defer { panel.close() }
        var renderer: MarkdownWebRenderer = panel.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)
        _ = try await call(renderer, "scrollToLine", arguments: [121, 0])
        let beforeValue = try await call(renderer, "visible")
        let before = try XCTUnwrap(MarkdownReadingPosition(state: try XCTUnwrap(beforeValue as? [String: Any])))
        XCTAssertGreaterThan(before.line, 100)

        let o1 = await panel.navigate(to: target, fragment: nil, origin: .palette); XCTAssertEqual(o1, .navigated)
        await rendered(renderer, revision: 2)
        let o2 = await panel.navigateBack(); XCTAssertEqual(o2, .navigated)
        await rendered(renderer, revision: 3)
        let liveValue = try await call(renderer, "visible")
        let live = try XCTUnwrap(MarkdownReadingPosition(state: try XCTUnwrap(liveValue as? [String: Any])))
        XCTAssertEqual(live.line, before.line, "live Back must restore the source position")

        let o3 = await panel.navigateForward(); XCTAssertEqual(o3, .navigated)
        await rendered(renderer, revision: 4)
        // Evict, then go back while no renderer exists.
        panel.evictRenderer(renderer, position: MarkdownReadingPosition())
        XCTAssertNil(panel.renderer)
        let o4 = await panel.navigateBack(); XCTAssertEqual(o4, .navigated)
        XCTAssertEqual(panel.filePath, source.path)
        renderer = panel.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        window.contentView = renderer.webView
        await rendered(renderer, revision: 1)
        let evictedValue = try await call(renderer, "visible")
        let evicted = try XCTUnwrap(MarkdownReadingPosition(state: try XCTUnwrap(evictedValue as? [String: Any])))
        XCTAssertEqual(evicted.line, before.line, "Back while evicted must restore the source position")
    }
}

extension MarkdownWebRendererTests {
    func testMarkdownLinkDestinationModifierInvertsDefaultAndAnchorsStayInPanel() async throws {
        let document = URL(fileURLWithPath: "/tmp/source.md")
        let markdownTarget = MarkdownLinkTarget.resolve("target.md", documentPath: document.path)
        for defaultIsNewPanel in [false, true] {
            for metaHeld in [false, true] {
                XCTAssertEqual(
                    MarkdownWebRenderer.shouldOpenTargetInNewPanel(
                        markdownTarget,
                        metaHeld: metaHeld,
                        defaultIsNewPanel: defaultIsNewPanel
                    ),
                    metaHeld != defaultIsNewPanel,
                    "Cmd-click must invert defaultIsNewPanel=\(defaultIsNewPanel)"
                )
                XCTAssertFalse(
                    MarkdownWebRenderer.shouldOpenTargetInNewPanel(
                        .anchor,
                        metaHeld: metaHeld,
                        defaultIsNewPanel: defaultIsNewPanel
                    ),
                    "same-document anchors stay in this panel regardless of modifiers or mode"
                )
            }
        }

        _ = NSApplication.shared
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let appDelegate = AppDelegate.shared
        let priorManager = appDelegate?.workspaceManager
        appDelegate?.workspaceManager = manager
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("md-anchor-routing-\(UUID().uuidString)")
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer {
            appDelegate?.workspaceManager = priorManager
            workspace.teardownAllPanels()
            try? FileManager.default.removeItem(at: root)
        }
        let file = docs.appendingPathComponent("reader.md")
        try "# Reader\n\n## Details\n\nContent.\n".write(to: file, atomically: true, encoding: .utf8)
        let panel = try XCTUnwrap(workspace.newMarkdownPanel(inPane: pane, filePath: file.path, focus: false))
        let renderer = panel.ensureRenderer()
        let panelCount = workspace.panels.count
        let initialCount = panel.navigationHistory.entries.count
        let settingKey = "markdown.links.openInNewPanel"
        let priorSetting = UserDefaults.standard.object(forKey: settingKey)
        defer {
            if let priorSetting { UserDefaults.standard.set(priorSetting, forKey: settingKey) }
            else { UserDefaults.standard.removeObject(forKey: settingKey) }
        }
        var position = MarkdownReadingPosition()
        position.line = 8

        for defaultIsNewPanel in [false, true] {
            UserDefaults.standard.set(defaultIsNewPanel, forKey: settingKey)
            for metaHeld in [false, true] {
                let task = try XCTUnwrap(renderer.routeLink(
                    "#details",
                    modifiers: ["meta": metaHeld],
                    position: position
                ))
                await task.value
                XCTAssertEqual(workspace.panels.count, panelCount, "anchor routing must not create a duplicate panel")
                XCTAssertEqual(panel.navigationHistory.entries.count, initialCount + 1, "repeating the same anchor must not duplicate history")
                XCTAssertEqual(panel.navigationHistory.entries[0].readingPosition?.line, 8, "the source position is retained for Back")
                XCTAssertEqual(panel.navigationHistory.current?.target.fragment, "details")
            }
        }
    }

    func testRepeatedCurrentFragmentNavigationReappliesWithoutGrowingHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-repeat-fragment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reader.md")
        let content = "# Reader\n\n" + (1...40).map { "Filler \($0).\n\n" }.joined() + "## Details\n\nTarget section.\n"
        try content.write(to: file, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: file.path)
        defer { panel.close() }
        let renderer = panel.ensureRenderer()
        renderer.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(contentRect: renderer.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        defer { window.contentView = nil; window.close() }
        await rendered(renderer, revision: 1)

        let firstOutcome = await panel.navigate(to: file, fragment: "details", origin: .agentCLI)
        XCTAssertEqual(firstOutcome, .navigated)
        let firstValue = try await call(renderer, "visible")
        let firstState = try XCTUnwrap(firstValue as? [String: Any])
        XCTAssertEqual((firstState["heading"] as? [String: Any])?["text"] as? String, "Details")
        _ = try await call(renderer, "scrollToLine", arguments: [1, 0])
        let awayValue = try await call(renderer, "visible")
        let awayState = try XCTUnwrap(awayValue as? [String: Any])
        XCTAssertNotEqual((awayState["heading"] as? [String: Any])?["text"] as? String, "Details")

        let repeatOutcome = await panel.navigate(to: file, fragment: "details", origin: .agentCLI)
        XCTAssertEqual(repeatOutcome, .navigated)
        let restoredValue = try await call(renderer, "visible")
        let restored = try XCTUnwrap(restoredValue as? [String: Any])
        XCTAssertEqual((restored["heading"] as? [String: Any])?["text"] as? String, "Details", "the repeated command must reapply the fragment after scroll-away")
        XCTAssertEqual(panel.navigationHistory.entries.count, 2, "reapplying a current fragment must not create another history item")
    }

    func testCancelledSocketNavigationCannotCommitAfterTimeoutCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-cancel-navigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.md")
        let target = root.appendingPathComponent("target.md")
        try "# Source\n".write(to: source, atomically: true, encoding: .utf8)
        try "# Target\n".write(to: target, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: source.path)
        defer { panel.close() }
        let originalHistoryCount = panel.navigationHistory.entries.count
        let cancellation = MarkdownNavigationCancellation()

        // This is the socket timeout action: the caller has received timeout,
        // so any navigation still preparing must be unable to commit.
        cancellation.cancel()
        let outcome = await panel.navigate(
            to: target,
            fragment: nil,
            origin: .agentCLI,
            cancellation: cancellation
        )
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(panel.filePath, source.path)
        XCTAssertEqual(panel.navigationHistory.entries.count, originalHistoryCount)
        var committed = false
        XCTAssertFalse(cancellation.commitIfActive { committed = true })
        XCTAssertFalse(committed, "a canceled timeout request cannot run its late panel commit")
    }

    func testSupersededMarkdownNavigationCannotCommitOverNewerRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-superseded-navigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.md")
        let slow = root.appendingPathComponent("slow.md")
        let fast = root.appendingPathComponent("fast.md")
        try "# Source\n".write(to: source, atomically: true, encoding: .utf8)
        var slowContent = Data("# Slow\n".utf8)
        slowContent.append(Data(repeating: 0x20, count: 19 * 1024 * 1024))
        try slowContent.write(to: slow)
        try "# Fast\n".write(to: fast, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: source.path)
        defer { panel.close() }
        let slowRequestStarted = expectation(description: "slow request entered before the newer navigation")
        let slowRequest = Task { @MainActor in
            slowRequestStarted.fulfill()
            return await panel.navigate(to: slow, fragment: nil, origin: .agentCLI)
        }
        await fulfillment(of: [slowRequestStarted], timeout: 2)

        let latest = await panel.navigate(to: fast, fragment: nil, origin: .agentCLI)
        let stale = await slowRequest.value
        XCTAssertEqual(latest, .navigated)
        XCTAssertEqual(stale, .superseded)
        XCTAssertEqual(panel.filePath, fast.path, "the older request must not commit after a newer target")
        XCTAssertEqual(panel.navigationHistory.entries.count, 2)
        XCTAssertEqual(panel.navigationHistory.current?.target.fileURL.path, fast.path)
    }

    func testBreadcrumbShowsDocumentNameInFullAndCompactWidths() {
        XCTAssertEqual(
            MarkdownBreadcrumbText.full(filePath: "/repo/docs/reader.md", displayTitle: "reader.md", headingPath: ["Setup", "Install"]),
            "docs  ›  reader.md  ›  Setup  ›  Install"
        )
        XCTAssertEqual(
            MarkdownBreadcrumbText.compact(filePath: "/repo/docs/reader.md", displayTitle: "reader.md", headingPath: ["Setup", "Install"], compact: true),
            "reader.md  ›  Install"
        )
        XCTAssertEqual(
            MarkdownBreadcrumbText.compact(filePath: "/repo/docs/reader.md", displayTitle: "reader.md", headingPath: [], compact: true),
            "reader.md"
        )
    }
}
