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

    // MARK: - content_type byte cap (schema maxLength: 128)

    func testContentTypeAt128BytesAccepted() throws {
        let okType = String(repeating: "a", count: 128)
        let envelope = try MailboxEnvelope.build(
            from: "builder", to: "watcher", body: "hi", contentType: okType
        )
        XCTAssertEqual(envelope.contentType, okType)
    }

    func testContentTypeOver128BytesRejected() throws {
        let longType = String(repeating: "a", count: 129)
        XCTAssertThrowsError(
            try MailboxEnvelope.build(
                from: "builder", to: "watcher", body: "hi", contentType: longType
            )
        ) { error in
            XCTAssertEqual(error as? MailboxEnvelope.Error, .contentTypeTooLong(bytes: 129))
        }
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

    /// C11-347: the CLI-vs-raw-file byte-parity lock from the removed
    /// tests_v2/test_mailbox_parity.py, without a live app. Each `raw` line is
    /// what a raw-file sender writes: Python's
    /// `json.dumps(envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`.
    /// The CLI's envelope must encode to those bytes, and the dispatcher's
    /// validate-then-encode of a raw envelope (its inbox copy) must keep them.
    func testCLIAndRawFileSendersProduceIdenticalInboxBytes() throws {
        let id = "01K3A2B7X8PQRTVWYZ0123456J"
        func ts(_ seq: Int) -> String { String(format: "2026-04-24T00:00:00.%03dZ", seq) }
        func cli(_ seq: Int, body: String, topic: String? = nil, replyTo: String? = nil, inReplyTo: String? = nil,
                 urgent: Bool? = nil, ttlSeconds: Int? = nil, bodyRef: String? = nil, contentType: String? = nil) throws -> MailboxEnvelope {
            try MailboxEnvelope.build(
                from: "sender", to: "receiver", topic: topic, body: body, id: id, ts: ts(seq),
                replyTo: replyTo, inReplyTo: inReplyTo, urgent: urgent, ttlSeconds: ttlSeconds,
                bodyRef: bodyRef, contentType: contentType
            )
        }
        let cases: [(name: String, cli: MailboxEnvelope, raw: String)] = [
            ("minimal", try cli(0, body: "build green"),
             #"{"body":"build green","from":"sender","id":"01K3A2B7X8PQRTVWYZ0123456J","to":"receiver","ts":"2026-04-24T00:00:00.000Z","version":1}"#),
            ("urgent", try cli(1, body: "urgent payload", urgent: true),
             #"{"body":"urgent payload","from":"sender","id":"01K3A2B7X8PQRTVWYZ0123456J","to":"receiver","ts":"2026-04-24T00:00:00.001Z","urgent":true,"version":1}"#),
            ("topic-and-to", try cli(2, body: "topic + to", topic: "ci.status"),
             #"{"body":"topic + to","from":"sender","id":"01K3A2B7X8PQRTVWYZ0123456J","to":"receiver","topic":"ci.status","ts":"2026-04-24T00:00:00.002Z","version":1}"#),
            ("reply-chain", try cli(3, body: "reply body", replyTo: "sender", inReplyTo: "01K3A2B7X8PQRTVWYZ0123456K"),
             #"{"body":"reply body","from":"sender","id":"01K3A2B7X8PQRTVWYZ0123456J","in_reply_to":"01K3A2B7X8PQRTVWYZ0123456K","reply_to":"sender","to":"receiver","ts":"2026-04-24T00:00:00.003Z","version":1}"#),
            ("content-type-json", try cli(4, body: #"{"k":"v"}"#, contentType: "application/json"),
             #"{"body":"{\"k\":\"v\"}","content_type":"application/json","from":"sender","id":"01K3A2B7X8PQRTVWYZ0123456J","to":"receiver","ts":"2026-04-24T00:00:00.004Z","version":1}"#),
            ("body-ref", try cli(5, body: "", bodyRef: "/tmp/c11-parity-blob"),
             #"{"body":"","body_ref":"/tmp/c11-parity-blob","from":"sender","id":"01K3A2B7X8PQRTVWYZ0123456J","to":"receiver","ts":"2026-04-24T00:00:00.005Z","version":1}"#),
            ("ttl", try cli(6, body: "ephemeral", ttlSeconds: 600),
             #"{"body":"ephemeral","from":"sender","id":"01K3A2B7X8PQRTVWYZ0123456J","to":"receiver","ts":"2026-04-24T00:00:00.006Z","ttl_seconds":600,"version":1}"#),
            ("unicode-multiline", try cli(7, body: "café ✓ 界\nline two\ttabbed"),
             #"{"body":"café ✓ 界\nline two\ttabbed","from":"sender","id":"01K3A2B7X8PQRTVWYZ0123456J","to":"receiver","ts":"2026-04-24T00:00:00.007Z","version":1}"#),
        ]
        for (name, cliEnvelope, raw) in cases {
            let rawBytes = Data(raw.utf8)
            XCTAssertEqual(String(decoding: try cliEnvelope.encode(), as: UTF8.self), raw, "[\(name)] CLI bytes")
            let delivered = try MailboxEnvelope.validate(data: rawBytes).encode()
            XCTAssertEqual(String(decoding: delivered, as: UTF8.self), raw, "[\(name)] dispatcher re-encode of the raw file")
        }
    }
}
