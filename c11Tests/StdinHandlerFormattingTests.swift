import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class StdinHandlerFormattingTests: XCTestCase {

    // MARK: - Byte shape

    func testCanonicalEnvelopeFormatsAsExpectedBlock() throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "build green sha=abc",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )
        let block = StdinMailboxHandler.formatFramedBlock(envelope: envelope)

        // Leading blank line, opening tag, body, closing tag, trailing blank line.
        let expected = "\n<c11-msg from=\"builder\" id=\"01K3A2B7X8PQRTVWYZ0123456J\" ts=\"2026-04-23T10:15:42Z\" to=\"watcher\">\nbuild green sha=abc\n</c11-msg>\n"
        XCTAssertEqual(block, expected)
    }

    // MARK: - Attribute escaping

    func testAttributeQuotesAndAmpersandsAreEscaped() throws {
        let envelope = try MailboxEnvelope.build(
            from: "quotes\"in&name",
            to: "target",
            body: "unused",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )
        let block = StdinMailboxHandler.formatFramedBlock(envelope: envelope)
        XCTAssertTrue(
            block.contains("from=\"quotes&quot;in&amp;name\""),
            "attribute value must escape both \" and &; got \(block)"
        )
    }

    func testAttributeAngleBracketsAreEscaped() throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "<script>",
            body: "ok",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )
        let block = StdinMailboxHandler.formatFramedBlock(envelope: envelope)
        XCTAssertTrue(
            block.contains("to=\"&lt;script&gt;\""),
            "attribute angle brackets must escape; got \(block)"
        )
    }

    // MARK: - Body escaping

    func testBodyAngleBracketsAndAmpersandsAreEscaped() throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "a<b&c>d",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )
        let block = StdinMailboxHandler.formatFramedBlock(envelope: envelope)
        XCTAssertTrue(block.contains("a&lt;b&amp;c&gt;d"))
    }

    // MARK: - Forged-close defense

    /// A body that embeds a literal `</c11-msg>` must NOT break framing; the
    /// closing tag must emerge escaped.
    func testBodyCannotForgeClosingTag() throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "evil </c11-msg> stuff",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )
        let block = StdinMailboxHandler.formatFramedBlock(envelope: envelope)
        XCTAssertFalse(
            block.dropLast(10).contains("</c11-msg>"),
            "only the trailing real closing tag is allowed; body </c11-msg> must be escaped"
        )
        XCTAssertTrue(block.contains("evil &lt;/c11-msg&gt; stuff"))
        // And the block still ends with the real closing tag + newline.
        XCTAssertTrue(block.hasSuffix("</c11-msg>\n"))
    }

    // MARK: - Optional attributes

    func testOptionalAttributesAppearWhenSet() throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "hi",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z",
            replyTo: "builder",
            inReplyTo: "01K3A2B7X8PQRTVWYZ0123456K",
            urgent: true,
            ttlSeconds: 60
        )
        let block = StdinMailboxHandler.formatFramedBlock(envelope: envelope)
        XCTAssertTrue(block.contains("reply_to=\"builder\""))
        XCTAssertTrue(block.contains("in_reply_to=\"01K3A2B7X8PQRTVWYZ0123456K\""))
        XCTAssertTrue(block.contains("urgent=\"true\""))
        XCTAssertTrue(block.contains("ttl_seconds=\"60\""))
    }

    func testOptionalAttributesOmittedWhenAbsent() throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "hi",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )
        let block = StdinMailboxHandler.formatFramedBlock(envelope: envelope)
        XCTAssertFalse(block.contains("reply_to="))
        XCTAssertFalse(block.contains("in_reply_to="))
        XCTAssertFalse(block.contains("urgent="))
        XCTAssertFalse(block.contains("ttl_seconds="))
    }

    // MARK: - Write path outcomes (via injected writer)

    func testDeliverReportsOkOnWriterSuccess() async throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "hello",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )
        let handler = StdinMailboxHandler(writer: { _, bytes in
            .ok(bytes: bytes.utf8.count)
        })
        let surfaceId = UUID()
        let result = await handler.deliver(
            envelope: envelope,
            to: surfaceId,
            surfaceName: "watcher"
        )
        XCTAssertEqual(result.outcome, .ok)
        XCTAssertGreaterThan(result.bytes ?? 0, 0)
    }

    func testDeliverReportsClosedWhenSurfaceNotFound() async throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "hello",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )
        let handler = StdinMailboxHandler(writer: { _, _ in .surfaceNotFound })
        let result = await handler.deliver(
            envelope: envelope,
            to: UUID(),
            surfaceName: "watcher"
        )
        XCTAssertEqual(result.outcome, .closed)
    }

    func testDeliverReportsTimeoutWhenWriterHangs() async throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "hello",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )
        let handler = StdinMailboxHandler(
            writer: { _, _ in
                // Simulate a hang that exceeds the timeout deadline.
                Thread.sleep(forTimeInterval: 0.6)
                return .ok(bytes: 0)
            },
            timeout: .milliseconds(50)
        )
        let result = await handler.deliver(
            envelope: envelope,
            to: UUID(),
            surfaceName: "watcher"
        )
        XCTAssertEqual(result.outcome, .timeout)
    }

    /// The 500 ms timeout on `StdinMailboxHandler.deliver` is a *reporting*
    /// bound — the dispatcher logs `.timeout` and moves on even when the
    /// writer closure is still executing. This test proves that explicitly:
    /// a 5-second writer block must not delay `deliver(...)` past the
    /// configured timeout by more than a small slack. It does NOT prove
    /// that main is freed — `MainActor.run` isn't cancellable, and a
    /// genuinely blocking PTY write will keep main busy for the full 5 s.
    /// That honest distinction is documented in `StdinMailboxHandler.swift`
    /// and the plan's "Risks and unknowns" section.
    ///
    /// Regression lock for review cycle 1 P0 #5.
    func testDeliverReturnsTimeoutEvenWhenWriterBlocksMultipleSeconds() async throws {
        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "slow",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )

        // The writer is dispatched on MainActor via withTaskGroup; using
        // Thread.sleep blocks that thread for the whole interval — exactly
        // the scenario the reporting-bound documentation describes.
        let handler = StdinMailboxHandler(
            writer: { _, _ in
                Thread.sleep(forTimeInterval: 5.0)
                return .ok(bytes: 0)
            },
            timeout: .milliseconds(100)
        )

        let start = Date()
        let result = await handler.deliver(
            envelope: envelope,
            to: UUID(),
            surfaceName: "watcher"
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(
            result.outcome,
            .timeout,
            "deliver must report .timeout when the writer blocks past the deadline"
        )

        // 100 ms timeout + slack for scheduling/structured-concurrency
        // overhead. If deliver waited for the writer's 5 s Thread.sleep
        // to finish, this would be somewhere near 5.0; anywhere below ~2 s
        // proves the reporting-bound behavior holds.
        XCTAssertLessThan(
            elapsed,
            2.0,
            "deliver must return on the timeout, not wait for the full writer block (elapsed=\(elapsed)s)"
        )
    }
}
