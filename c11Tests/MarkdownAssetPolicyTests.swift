import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MarkdownAssetPolicyTests: XCTestCase {
    func testScopedNestedAndInternalSymlinkImagesAreReadable() throws {
        try fixture { root, policy in
            let sub = root.appendingPathComponent("doc/sub directory")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let data = Self.image
            try data.write(to: sub.appendingPathComponent("one.png"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("doc/alias.png"), withDestinationURL: sub.appendingPathComponent("one.png"))
            for path in ["sub%20directory/one.png", "alias.png"] {
                let served = try policy.resource(for: URL(string: "c11md-asset://doc/" + path)!)
                XCTAssertEqual(served.data, data)
                XCTAssertEqual(served.mime, "image/png")
            }
        }
    }

    func testTraversalSymlinkAndSchemeEscapesAreDenied() throws {
        try fixture { root, policy in
            try Data("private".utf8).write(to: root.appendingPathComponent("private.png"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("doc/escape.png"), withDestinationURL: root.appendingPathComponent("private.png"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("doc/escape"), withDestinationURL: root)
            for path in ["../private.png", "%2e%2e/private.png", "escape.png", "escape/private.png", "%2f../private.png", "a%2f..%2fprivate.png", "%00.png", "a%5c..%5cprivate.png"] {
                XCTAssertThrowsError(try policy.resource(for: URL(string: "c11md-asset://doc/" + path)!), path)
            }
            for url in ["file:///tmp/one.png", "https://example.invalid/one.png", "c11md://doc/one.png", "c11md-asset://bundle/one.png", "c11md-asset://user@doc/one.png", "c11md-asset://doc:80/one.png"] {
                XCTAssertThrowsError(try policy.resource(for: URL(string: url)!), url)
            }
        }
    }

    func testPinnedRootIgnoresDirectoryReplacement() throws {
        try fixture { root, policy in
            try Self.image.write(to: root.appendingPathComponent("doc/one.png"))
            try FileManager.default.moveItem(at: root.appendingPathComponent("doc"), to: root.appendingPathComponent("old-doc"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("doc"), withIntermediateDirectories: true)
            try (Self.image + Data([0])).write(to: root.appendingPathComponent("doc/one.png"))
            XCTAssertEqual(try policy.resource(for: URL(string: "c11md-asset://doc/one.png")!).data, Self.image)
        }
    }

    func testDoubleEncodedTraversalIsOnlyALiteralFilename() throws {
        try fixture { root, policy in
            try Self.image.write(to: root.appendingPathComponent("outside.png"))
            let request = URL(string: "c11md-asset://doc/%252e%252e/outside.png")!
            // A second decode would turn this component into '..'. It must
            // neither serve the outside image nor reject a valid literal name.
            XCTAssertThrowsError(try policy.resource(for: request))
            let literal = root.appendingPathComponent("doc/%2e%2e")
            try FileManager.default.createDirectory(at: literal, withIntermediateDirectories: true)
            let localImage = Self.image + Data([0])
            try localImage.write(to: literal.appendingPathComponent("outside.png"))
            XCTAssertEqual(try policy.resource(for: request).data, localImage)
            XCTAssertThrowsError(try policy.resource(for: URL(string: "c11md-asset://doc/%2e%2e/outside.png")!))
        }
    }

    func testOnlyBundleCanServeCodeAndEntryReceivesCSP() throws {
        try fixture { root, policy in
            try Data("<!doctype html><html><head></head><body></body></html>".utf8).write(to: root.appendingPathComponent("bundle/index.html"))
            try Data("window.bundleLoaded=true".utf8).write(to: root.appendingPathComponent("bundle/app.js"))
            let served = try policy.resource(for: MarkdownAssetPolicy.entryURL)
            XCTAssertTrue(try XCTUnwrap(String(data: served.data, encoding: .utf8)).contains(MarkdownAssetPolicy.csp))
            XCTAssertEqual(served.mime, "text/html")
            XCTAssertEqual(try policy.resource(for: URL(string: "c11md://bundle/app.js")!).mime, "text/javascript")
            for path in ["app.js", "evil.html", "evil.svg", "index.html"] {
                try Data("<script>throw 1</script>".utf8).write(to: root.appendingPathComponent("doc/" + path))
                XCTAssertThrowsError(try policy.resource(for: URL(string: "c11md-asset://doc/" + path)!))
            }
            XCTAssertThrowsError(try policy.resource(for: URL(string: "c11md://bundle/../doc/app.js")!))
        }
    }

    func testLinkPolicyAllowsAnchorsRelativeMarkdownAndWeb() {
        let doc = "/tmp/docs/plan.md"
        XCTAssertEqual(MarkdownLinkTarget.resolve("#a", documentPath: doc), .anchor)
        XCTAssertEqual(MarkdownLinkTarget.resolve("other.md", documentPath: doc), .markdown(URL(fileURLWithPath: "/tmp/docs/other.md")))
        XCTAssertEqual(MarkdownLinkTarget.resolve("https://example.invalid/page", documentPath: doc), .web(URL(string: "https://example.invalid/page")!))
        for href in ["javascript:alert(1)", "data:text/html,test", "file:///etc/passwd", "/tmp/test.md", "//example.invalid/x.md", "script.sh", "evil.command", "file:///System/Applications/Calculator.app", "hidden%00.md", "https://user:pass@example.invalid/", "\nhttps://example.invalid/"] {
            XCTAssertEqual(MarkdownLinkTarget.resolve(href, documentPath: doc), .blocked, href)
        }
    }

    func testLinkPolicyAllowsOnlyValidatedMailtoURLs() {
        let doc = "/tmp/docs/plan.md"
        let href = "mailto:reader@example.invalid?subject=Plan&body=Please%20review"
        XCTAssertEqual(MarkdownLinkTarget.resolve(href, documentPath: doc), .mailto(URL(string: href)!))
        XCTAssertEqual(MarkdownLinkTarget.resolve("MAILTO:reader@example.invalid", documentPath: doc), .mailto(URL(string: "mailto:reader@example.invalid")!))
        for href in [
            "mailto:", "mailto:not-an-address", "mailto:reader@-example.invalid",
            "mailto:reader@example.invalid%0D%0ABcc:attacker@example.invalid",
            "mailto:reader@example.invalid?bcc=attacker@example.invalid%0D%0Ato:other@example.invalid",
            "mailto:reader@example.invalid?attachment=file%3A%2F%2F%2Fetc%2Fpasswd",
            "mailto:reader@example.invalid#fragment", "mailto://reader@example.invalid"
        ] {
            XCTAssertEqual(MarkdownLinkTarget.resolve(href, documentPath: doc), .blocked, href)
        }
    }

    func testMarkdownNavigationConfinesAutomaticLinksToRepositoryAndRejectsEscapingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-navigation-\(UUID().uuidString)")
        let repository = root.appendingPathComponent("project")
        let documents = repository.appendingPathComponent("docs")
        let outside = root.appendingPathComponent("outside.md")
        let current = documents.appendingPathComponent("current.md")
        let target = repository.appendingPathComponent("guide/install.md")
        let escapedLink = documents.appendingPathComponent("escape.md")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Current".write(to: current, atomically: true, encoding: .utf8)
        try "# Installation\n\nSafe section".write(to: target, atomically: true, encoding: .utf8)
        try "# Outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: escapedLink, withDestinationURL: outside)

        let sameDocument = MarkdownNavigationPolicy.prepare(
            MarkdownNavigationTarget(fileURL: current, fragment: "current"),
            currentFilePath: current.path,
            origin: .documentLink
        )
        guard case let .ready(path, content, _, scopeRootPath) = sameDocument else {
            return XCTFail("same-document anchors should navigate without rereading content: \(sameDocument)")
        }
        XCTAssertEqual(path, current.path)
        XCTAssertNil(content)
        XCTAssertEqual(scopeRootPath, repository.resolvingSymlinksInPath().standardizedFileURL.path)

        let inRepository = MarkdownNavigationPolicy.prepare(
            MarkdownNavigationTarget(fileURL: target, fragment: "installation"),
            currentFilePath: current.path,
            origin: .documentLink
        )
        guard case let .ready(targetPath, targetContent, _, targetScope) = inRepository else {
            return XCTFail("a repository-local target should be readable: \(inRepository)")
        }
        XCTAssertEqual(targetPath, target.path)
        XCTAssertTrue(try XCTUnwrap(targetContent).contains("Safe section"))
        XCTAssertEqual(targetScope, repository.path)

        for escaped in [outside, escapedLink] {
            let result = MarkdownNavigationPolicy.prepare(
                MarkdownNavigationTarget(fileURL: escaped),
                currentFilePath: current.path,
                origin: .documentLink
            )
            guard case .rejected(.outsideScope) = result else {
                return XCTFail("automatic navigation must reject \(escaped.path): \(result)")
            }
        }
    }

    func testMarkdownNavigationOutcomesValidateTypeExistenceAndExplicitAgentTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-navigation-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source/reader.md")
        let outside = root.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Reader".write(to: source, atomically: true, encoding: .utf8)
        try "Explicit target".write(to: outside, atomically: true, encoding: .utf8)

        let invalidExtension = MarkdownNavigationPolicy.prepare(
            MarkdownNavigationTarget(fileURL: outside),
            currentFilePath: source.path,
            origin: .palette
        )
        guard case .rejected(.invalidTarget) = invalidExtension else {
            return XCTFail("automatic navigation only accepts Markdown files: \(invalidExtension)")
        }
        let missing = MarkdownNavigationPolicy.prepare(
            MarkdownNavigationTarget(fileURL: root.appendingPathComponent("missing.md")),
            currentFilePath: source.path,
            origin: .backlink
        )
        guard case .rejected(.notFound) = missing else {
            return XCTFail("missing Markdown targets should report notFound: \(missing)")
        }
        let longFragment = MarkdownNavigationPolicy.prepare(
            MarkdownNavigationTarget(fileURL: source, fragment: String(repeating: "a", count: 4097)),
            currentFilePath: source.path,
            origin: .palette
        )
        guard case .rejected(.invalidTarget) = longFragment else {
            return XCTFail("oversized fragments should report invalidTarget: \(longFragment)")
        }

        let explicitAgentTarget = MarkdownNavigationPolicy.prepare(
            MarkdownNavigationTarget(fileURL: outside),
            currentFilePath: source.path,
            origin: .agentCLI
        )
        guard case let .ready(path, content, _, scopeRootPath) = explicitAgentTarget else {
            return XCTFail("an explicit agent-selected target should remain available: \(explicitAgentTarget)")
        }
        XCTAssertEqual(path, outside.path)
        XCTAssertEqual(content, "Explicit target")
        XCTAssertNil(scopeRootPath)

        let historyRestore = MarkdownNavigationPolicy.prepare(
            MarkdownNavigationTarget(fileURL: outside),
            currentFilePath: source.path,
            origin: .history,
            allowOutsideScope: true
        )
        guard case .ready = historyRestore else {
            return XCTFail("history should restore an explicitly agent-selected entry: \(historyRestore)")
        }
    }

    private static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!

    func testDisguisedExecutableAndDirectoryAreNotImages() throws {
        try fixture { root, policy in
            try Data("<svg onload='alert(1)'></svg>".utf8).write(to: root.appendingPathComponent("doc/disguised.png"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("doc/folder.png"), withIntermediateDirectories: true)
            for path in ["disguised.png", "folder.png"] {
                XCTAssertThrowsError(try policy.resource(for: URL(string: "c11md-asset://doc/" + path)!))
            }
        }
    }

    private func fixture(_ body: (URL, MarkdownAssetPolicy) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("doc"), bundle = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: doc, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try body(root, MarkdownAssetPolicy(bundle: MarkdownAssetRoot(directory: bundle), document: MarkdownAssetRoot(directory: doc)))
    }
}
