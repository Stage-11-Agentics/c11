import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MailboxEnvelopeValidationTests: XCTestCase {

    // MARK: - Fixture location

    /// `spec/fixtures/envelopes/` is at the repo root; the test source sits at
    /// `<repo>/c11Tests/MailboxEnvelopeValidationTests.swift`. `#filePath` is
    /// absolute and resolves to the actual on-disk path of this source file
    /// at compile time, regardless of whether the tests run from CI or a
    /// worktree, so walking up one directory reaches the repo root.
    private var fixturesDir: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("spec", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("envelopes", isDirectory: true)
    }

    private func loadFixture(_ name: String) throws -> Data {
        let url = fixturesDir.appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    // MARK: - Valid fixtures

    func testFixturesDirExists() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixturesDir.path),
            "fixtures dir must exist at \(fixturesDir.path)"
        )
    }

    func testAllValidFixturesParse() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: fixturesDir,
            includingPropertiesForKeys: nil
        )
        let validFiles = entries
            .filter { $0.lastPathComponent.hasPrefix("valid-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(validFiles.isEmpty, "no valid fixtures found")
        XCTAssertEqual(validFiles.count, 5, "expected 5 valid fixtures, got \(validFiles.count)")

        for url in validFiles {
            let data = try Data(contentsOf: url)
            XCTAssertNoThrow(
                try MailboxEnvelope.validate(data: data),
                "fixture \(url.lastPathComponent) must parse successfully"
            )
        }
    }

    func testValidMinimalPayload() throws {
        let envelope = try MailboxEnvelope.validate(
            data: loadFixture("valid-minimal.json")
        )
        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.from, "builder")
        XCTAssertEqual(envelope.to, "watcher")
        XCTAssertEqual(envelope.body, "build green sha=abc")
        XCTAssertNil(envelope.topic)
    }

    func testValidBodyRefHasEmptyBody() throws {
        let envelope = try MailboxEnvelope.validate(
            data: loadFixture("valid-body-ref.json")
        )
        XCTAssertEqual(envelope.body, "")
        XCTAssertEqual(envelope.bodyRef, "/tmp/c11-blob-example.json")
        XCTAssertEqual(envelope.contentType, "application/json")
    }

    func testValidWithExtCarriesExt() throws {
        let envelope = try MailboxEnvelope.validate(
            data: loadFixture("valid-with-ext.json")
        )
        XCTAssertEqual(envelope.urgent, true)
        XCTAssertEqual(envelope.ttlSeconds, 3600)
        XCTAssertEqual(envelope.ext?["trace_id"] as? String, "abc-123")
    }

    // MARK: - Invalid fixtures (one per documented rule)

    func testInvalidMissingVersion() throws {
        XCTAssertThrowsError(
            try MailboxEnvelope.validate(data: loadFixture("invalid-missing-version.json"))
        ) { error in
            XCTAssertEqual(error as? MailboxEnvelope.Error, .missingField("version"))
        }
    }

    func testInvalidWrongVersionType() throws {
        XCTAssertThrowsError(
            try MailboxEnvelope.validate(data: loadFixture("invalid-wrong-version-type.json"))
        ) { error in
            XCTAssertEqual(error as? MailboxEnvelope.Error, .wrongFieldType("version"))
        }
    }

    func testInvalidNoRecipient() throws {
        XCTAssertThrowsError(
            try MailboxEnvelope.validate(data: loadFixture("invalid-no-recipient.json"))
        ) { error in
            XCTAssertEqual(error as? MailboxEnvelope.Error, .noRecipient)
        }
    }

    func testInvalidUnknownTopLevelKey() throws {
        XCTAssertThrowsError(
            try MailboxEnvelope.validate(data: loadFixture("invalid-unknown-top-level-key.json"))
        ) { error in
            XCTAssertEqual(error as? MailboxEnvelope.Error, .unknownTopLevelKey("foo"))
        }
    }

    func testInvalidOversizeBody() throws {
        XCTAssertThrowsError(
            try MailboxEnvelope.validate(data: loadFixture("invalid-oversize-body.json"))
        ) { error in
            guard case .bodyTooLarge(let bytes) = error as? MailboxEnvelope.Error else {
                XCTFail("expected bodyTooLarge, got \(error)")
                return
            }
            XCTAssertGreaterThan(bytes, MailboxEnvelope.maxBodyBytes)
        }
    }

    func testInvalidBodyAndBodyRef() throws {
        XCTAssertThrowsError(
            try MailboxEnvelope.validate(data: loadFixture("invalid-body-and-body-ref.json"))
        ) { error in
            XCTAssertEqual(error as? MailboxEnvelope.Error, .bodyAndBodyRefConflict)
        }
    }

    func testInvalidBadTimestamp() throws {
        XCTAssertThrowsError(
            try MailboxEnvelope.validate(data: loadFixture("invalid-bad-ts.json"))
        ) { error in
            guard case .invalidTimestamp = error as? MailboxEnvelope.Error else {
                XCTFail("expected invalidTimestamp, got \(error)")
                return
            }
        }
    }

    func testInvalidBadULID() throws {
        XCTAssertThrowsError(
            try MailboxEnvelope.validate(data: loadFixture("invalid-bad-ulid.json"))
        ) { error in
            guard case .invalidULID = error as? MailboxEnvelope.Error else {
                XCTFail("expected invalidULID, got \(error)")
                return
            }
        }
    }

    // MARK: - Build + round-trip

    func testBuildFillsAutoFields() throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "hello"
        )
        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.from, "builder")
        XCTAssertEqual(envelope.to, "watcher")
        XCTAssertEqual(envelope.body, "hello")
        XCTAssertEqual(envelope.id.count, 26, "auto-generated id is a 26-char ULID")
        XCTAssertFalse(envelope.ts.isEmpty)
    }

    func testBuildThenEncodeSortsKeys() throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "hello",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )
        let bytes = try envelope.encode()
        let expected = Data(#"{"body":"hello","from":"builder","id":"01K3A2B7X8PQRTVWYZ0123456J","to":"watcher","ts":"2026-04-23T10:15:42Z","version":1}"#.utf8)
        XCTAssertEqual(bytes, expected)
    }

    func testEncodeDoesNotEscapeForwardSlashes() throws {
        // Swift's default JSONSerialization escapes `/` as `\/`; Python's
        // json.dumps does not. The parity test asserts CLI == raw byte-for-byte,
        // so the encoder must emit a literal slash. Regression lock for
        // review cycle 1 P0 #2.
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z",
            bodyRef: "/tmp/c11-parity-blob"
        )
        let bytes = try envelope.encode()
        let text = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertTrue(
            text.contains("/tmp/c11-parity-blob"),
            "body_ref must round-trip as literal slashes, got: \(text)"
        )
        XCTAssertFalse(
            text.contains(#"\/"#),
            "encoder must not escape `/` as `\\/`, got: \(text)"
        )
    }

    func testBuildRoundTripValidates() throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            topic: "ci.status",
            body: "build green",
            urgent: true,
            ttlSeconds: 600
        )
        let data = try envelope.encode()
        XCTAssertNoThrow(try MailboxEnvelope.validate(data: data))
    }

    func testBuildRejectsNoRecipient() {
        XCTAssertThrowsError(
            try MailboxEnvelope.build(from: "builder", body: "hello")
        ) { error in
            XCTAssertEqual(error as? MailboxEnvelope.Error, .noRecipient)
        }
    }

    func testBuildRejectsOversizeBody() {
        let oversize = String(repeating: "x", count: MailboxEnvelope.maxBodyBytes + 1)
        XCTAssertThrowsError(
            try MailboxEnvelope.build(from: "builder", to: "watcher", body: oversize)
        ) { error in
            guard case .bodyTooLarge = error as? MailboxEnvelope.Error else {
                XCTFail("expected bodyTooLarge, got \(error)")
                return
            }
        }
    }
}
