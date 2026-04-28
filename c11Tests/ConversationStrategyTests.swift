import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure tests for the four v1 strategies. Per `CLAUDE.md`, never run
/// locally — CI only.
final class ConversationStrategyTests: XCTestCase {

    private let validUUID = "abc12345-ef67-890a-bcde-f0123456789a"
    private let validUUID2 = "ddd11111-2222-3333-4444-555566667777"
    private let cwd = "/Users/foo/proj"

    // MARK: - Registry

    func testV1RegistryContainsTheFourKinds() {
        let r = ConversationStrategyRegistry.v1
        XCTAssertNotNil(r.strategy(forKind: "claude-code"))
        XCTAssertNotNil(r.strategy(forKind: "codex"))
        XCTAssertNotNil(r.strategy(forKind: "opencode"))
        XCTAssertNotNil(r.strategy(forKind: "kimi"))
        XCTAssertNil(r.strategy(forKind: "cursor"))
    }

    // MARK: - Claude Code strategy

    func testClaudeCodePushWinsOverScrape() {
        let strategy = ClaudeCodeStrategy()
        let push = ConversationRef(
            kind: "claude-code",
            id: validUUID,
            capturedAt: Date(),
            capturedVia: .hook,
            state: .alive
        )
        let scrape = ScrapeCandidate(
            id: validUUID2,
            filePath: "/tmp/x.jsonl",
            mtime: Date().addingTimeInterval(-30),
            size: 1024,
            cwd: cwd
        )
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: cwd,
            push: push,
            scrapeCandidates: [scrape]
        )
        XCTAssertEqual(strategy.capture(inputs: inputs)?.id, validUUID)
    }

    func testClaudeCodeResumeEmitsTypeCommandWithQuotedId() {
        let strategy = ClaudeCodeStrategy()
        let ref = ConversationRef(
            kind: "claude-code",
            id: validUUID,
            capturedAt: Date(),
            capturedVia: .hook,
            state: .alive
        )
        guard case .typeCommand(let text, let submit) = strategy.resume(ref: ref) else {
            XCTFail("expected typeCommand")
            return
        }
        XCTAssertTrue(submit)
        XCTAssertTrue(text.contains("claude --dangerously-skip-permissions --resume"))
        XCTAssertTrue(text.contains(validUUID))
        XCTAssertTrue(text.contains("'\(validUUID)'"), "id must be shell-quoted in the synthesised command: \(text)")
    }

    func testClaudeCodeResumeSkipsPlaceholder() {
        let strategy = ClaudeCodeStrategy()
        let ref = ConversationRef(
            kind: "claude-code",
            id: "wrapper-claim:foo",
            placeholder: true,
            capturedAt: Date(),
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        guard case .skip(let reason) = strategy.resume(ref: ref) else {
            XCTFail("expected skip")
            return
        }
        XCTAssertTrue(reason.contains("placeholder"))
    }

    func testClaudeCodeResumeSkipsInvalidId() {
        let strategy = ClaudeCodeStrategy()
        let ref = ConversationRef(
            kind: "claude-code",
            id: "fake; rm -rf $HOME",
            capturedAt: Date(),
            capturedVia: .hook,
            state: .alive
        )
        guard case .skip = strategy.resume(ref: ref) else {
            XCTFail("expected skip on invalid id (defence-in-depth)")
            return
        }
    }

    func testClaudeCodeIsValidIdMatchesUUIDv4() {
        let strategy = ClaudeCodeStrategy()
        XCTAssertTrue(strategy.isValidId(validUUID))
        XCTAssertFalse(strategy.isValidId(""))
        XCTAssertFalse(strategy.isValidId("not-a-uuid"))
        XCTAssertFalse(strategy.isValidId("abc; rm -rf"))
    }

    // MARK: - Codex strategy

    func testCodexCaptureSingleCandidateMarksAlive() {
        let strategy = CodexStrategy()
        let claimTime = Date().addingTimeInterval(-60)
        let candidate = ScrapeCandidate(
            id: validUUID,
            filePath: "/tmp/codex/\(validUUID).jsonl",
            mtime: claimTime.addingTimeInterval(30),
            size: 4096,
            cwd: cwd
        )
        let claim = ConversationRef(
            kind: "codex",
            id: "wrapper-claim:S1:1",
            placeholder: true,
            cwd: cwd,
            capturedAt: claimTime,
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: cwd,
            wrapperClaim: claim,
            scrapeCandidates: [candidate]
        )
        let ref = strategy.capture(inputs: inputs)
        XCTAssertEqual(ref?.id, validUUID)
        XCTAssertEqual(ref?.state, .alive)
        XCTAssertFalse(ref?.placeholder ?? true)
    }

    /// MERGE-BLOCKER fixture-equivalent unit test: two sessions match the
    /// surface filter (cwd + mtime ≥ claim) → strategy returns `state =
    /// unknown` with diagnosticReason, and `resume` returns `.skip`.
    /// Reproduces the 2026-04-27 staging-QA failure shape.
    func testCodexAmbiguousCandidatesPolicy() {
        let strategy = CodexStrategy()
        let claimTime = Date().addingTimeInterval(-300)
        let cand1 = ScrapeCandidate(
            id: validUUID,
            filePath: "/tmp/codex/\(validUUID).jsonl",
            mtime: claimTime.addingTimeInterval(30),
            size: 4096,
            cwd: cwd
        )
        let cand2 = ScrapeCandidate(
            id: validUUID2,
            filePath: "/tmp/codex/\(validUUID2).jsonl",
            mtime: claimTime.addingTimeInterval(60),
            size: 8192,
            cwd: cwd
        )
        let claim = ConversationRef(
            kind: "codex",
            id: "wrapper-claim:S1:1",
            placeholder: true,
            cwd: cwd,
            capturedAt: claimTime,
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: cwd,
            wrapperClaim: claim,
            scrapeCandidates: [cand1, cand2]
        )
        let ref = strategy.capture(inputs: inputs)
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.state, .unknown,
                       "ambiguous candidates must transition to unknown, not alive")
        XCTAssertEqual(ref?.id, validUUID2,
                       "id should be set to most plausible (newest mtime)")
        XCTAssertTrue(ref?.diagnosticReason?.contains("ambiguous") ?? false,
                      "diagnosticReason must surface ambiguity for operator visibility")

        // resume must NOT auto-resume an ambiguous ref
        guard case .skip(let reason) = strategy.resume(ref: ref!) else {
            XCTFail("expected skip on ambiguous ref")
            return
        }
        XCTAssertEqual(reason, "ambiguous")
    }

    func testCodexResumeUsesSpecificIdNotLast() {
        let strategy = CodexStrategy()
        let ref = ConversationRef(
            kind: "codex",
            id: validUUID,
            capturedAt: Date(),
            capturedVia: .scrape,
            state: .alive
        )
        guard case .typeCommand(let text, _) = strategy.resume(ref: ref) else {
            XCTFail("expected typeCommand")
            return
        }
        XCTAssertTrue(text.contains("codex resume"))
        XCTAssertFalse(text.contains("--last"),
                       "codex must resume the specific id, not --last (the bug this primitive fixes)")
        XCTAssertTrue(text.contains(validUUID))
    }

    func testCodexCwdMismatchFiltersCandidate() {
        let strategy = CodexStrategy()
        let candidate = ScrapeCandidate(
            id: validUUID,
            filePath: "/tmp/codex/\(validUUID).jsonl",
            mtime: Date(),
            size: 4096,
            cwd: "/different/cwd"
        )
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: cwd,
            scrapeCandidates: [candidate]
        )
        // No claim, no push, candidate cwd doesn't match → no ref.
        XCTAssertNil(strategy.capture(inputs: inputs))
    }

    // MARK: - Opencode / Kimi (fresh-launch)

    func testOpencodePlaceholderResumeSkips() {
        let strategy = OpencodeStrategy()
        let ref = ConversationRef(
            kind: "opencode",
            id: "wrapper-claim:foo",
            placeholder: true,
            capturedAt: Date(),
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        guard case .skip(let reason) = strategy.resume(ref: ref) else {
            XCTFail("expected skip")
            return
        }
        XCTAssertEqual(reason, "fresh-launch-only")
    }

    func testKimiAliveTypesShellQuotedCommand() {
        let strategy = KimiStrategy()
        let ref = ConversationRef(
            kind: "kimi",
            id: "real-id",
            placeholder: false,
            capturedAt: Date(),
            capturedVia: .hook,
            state: .alive
        )
        guard case .typeCommand(let text, let submit) = strategy.resume(ref: ref) else {
            XCTFail("expected typeCommand")
            return
        }
        XCTAssertEqual(text, "'kimi'")
        XCTAssertTrue(submit)
    }

    // MARK: - Shell-quoting helper

    func testConversationShellQuoteEscapesEmbeddedQuote() {
        let q = conversationShellQuote("a'b")
        XCTAssertEqual(q, "'a'\\''b'")
    }

    func testConversationShellQuoteWrapsBareValue() {
        XCTAssertEqual(conversationShellQuote("abc"), "'abc'")
    }
}
