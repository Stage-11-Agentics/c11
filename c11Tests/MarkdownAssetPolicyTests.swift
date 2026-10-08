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

    func testLinkPolicyAllowsAnchorsRelativeMarkdownAndWebOnly() {
        let doc = "/tmp/docs/plan.md"
        XCTAssertEqual(MarkdownLinkTarget.resolve("#a", documentPath: doc), .anchor)
        XCTAssertEqual(MarkdownLinkTarget.resolve("other.md", documentPath: doc), .markdown(URL(fileURLWithPath: "/tmp/docs/other.md")))
        XCTAssertEqual(MarkdownLinkTarget.resolve("https://example.invalid/page", documentPath: doc), .web(URL(string: "https://example.invalid/page")!))
        for href in ["javascript:alert(1)", "data:text/html,test", "file:///etc/passwd", "/tmp/test.md", "//example.invalid/x.md", "script.sh", "evil.command", "file:///System/Applications/Calculator.app", "hidden%00.md", "mailto:a@example.invalid", "https://user:pass@example.invalid/", "\nhttps://example.invalid/"] {
            XCTAssertEqual(MarkdownLinkTarget.resolve(href, documentPath: doc), .blocked, href)
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
