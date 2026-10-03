import Foundation
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

private final class PromptInputTargetIdentity {}

final class PromptInputClassifierTests: XCTestCase {
    private struct Span {
        let text: String
        var faint = false
    }

    private struct Row {
        let y: Int
        let spans: [Span]
        var softWrap = false
        var wrapContinuation = false
    }

    private let rule = String(repeating: "─", count: 40)

    func testEmptyAndFaintSuggestionAreDistinct() {
        let empty = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0} ")]),
            Row(y: 2, spans: [Span(text: rule)]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(empty), .init(state: .empty, draftLength: nil))

        let suggestion = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0} "), Span(text: "Try \"fix lint errors\"", faint: true)]),
            Row(y: 2, spans: [Span(text: rule)]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(suggestion), .init(state: .suggestion, draftLength: nil))
    }

    func testDraftReportsOnlyLengthAndNeverPromptText() throws {
        let sentinel = "NEVER_EXPOSE_PROMPT_9F31"
        let input = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}"), Span(text: sentinel)]),
            Row(y: 2, spans: [Span(text: rule)]),
        ], cursorY: 1)

        let classification = PromptInputClassifier.classify(input)
        XCTAssertEqual(classification.state, .draft)
        XCTAssertEqual(classification.draftLength, sentinel.unicodeScalars.count)

        let fields = classification.responseFields(source: "active_screen", observedAtMs: 123)
        let json = try JSONSerialization.data(withJSONObject: fields)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains(sentinel))
        XCTAssertEqual(fields["draft_length"] as? Int, sentinel.unicodeScalars.count)
    }

    func testComposerTextIsExactForDraftsAndUnavailableForOtherStates() {
        let body = "FEED-ANSWER-FIXTURE"
        let singleLine = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}" + body)]),
            Row(y: 2, spans: [Span(text: rule)]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.composerText(singleLine), body)

        let multiline = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}first line")]),
            Row(y: 2, spans: [Span(text: "")]),
            Row(y: 3, spans: [Span(text: "  third line")]),
            Row(y: 4, spans: [Span(text: rule)]),
        ], cursorY: 3)
        XCTAssertEqual(PromptInputClassifier.composerText(multiline), "first line\n\n  third line")

        let suggestion = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0} "), Span(text: "suggested text", faint: true)]),
            Row(y: 2, spans: [Span(text: rule)]),
        ], cursorY: 1)
        XCTAssertNil(PromptInputClassifier.composerText(suggestion))

        let dialog = region([
            Row(y: 0, spans: [Span(text: "Would you like to make this plan?")]),
            Row(y: 1, spans: [Span(text: "❯ Yes, implement this plan")]),
            Row(y: 2, spans: [Span(text: "  No, keep planning")]),
            Row(y: 3, spans: [Span(text: "Enter to select · Esc to go back")]),
        ], cursorY: 3)
        XCTAssertNil(PromptInputClassifier.composerText(dialog))

        let unknown = region([Row(y: 0, spans: [Span(text: "ordinary terminal output")])], cursorY: 0)
        XCTAssertNil(PromptInputClassifier.composerText(unknown))
    }

    func testMultilineDraftSurvivesBlankCursorRow() {
        let input = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}first line")]),
            Row(y: 2, spans: [Span(text: "  second line")]),
            Row(y: 3, spans: [Span(text: "  ")]),
            Row(y: 4, spans: [Span(text: rule)]),
        ], cursorY: 3)

        let expectedLength = "first line\n  second line".unicodeScalars.count
        XCTAssertEqual(PromptInputClassifier.classify(input), .init(state: .draft, draftLength: expectedLength))
    }

    func testBlankRowsInsideAMultilineDraftAreContentNotTheEndOfTheComposer() {
        // Leading blank row: empty prompt row, a blank continuation, typed text on the cursor row.
        let leading = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}")]),
            Row(y: 2, spans: [Span(text: "  ")]),
            Row(y: 3, spans: [Span(text: "  typed after a blank line")]),
            Row(y: 4, spans: [Span(text: rule)]),
        ], cursorY: 3)
        XCTAssertEqual(
            PromptInputClassifier.classify(leading),
            .init(state: .draft, draftLength: "typed after a blank line".unicodeScalars.count)
        )

        // Embedded blank row between two typed rows, cursor on the last.
        let embedded = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}first")]),
            Row(y: 2, spans: [Span(text: "")]),
            Row(y: 3, spans: [Span(text: "  third")]),
            Row(y: 4, spans: [Span(text: rule)]),
        ], cursorY: 3)
        XCTAssertEqual(
            PromptInputClassifier.classify(embedded),
            .init(state: .draft, draftLength: "first\n\n  third".unicodeScalars.count)
        )

        // A rule above the cursor row means the typed row was never reached: unknown, not empty.
        let ruleBeforeCursor = region([
            Row(y: 0, spans: [Span(text: "❯\u{00A0}")]),
            Row(y: 1, spans: [Span(text: rule)]),
            Row(y: 2, spans: [Span(text: "  typed below a rule")]),
        ], cursorY: 2)
        XCTAssertEqual(PromptInputClassifier.classify(ruleBeforeCursor).state, .unknown)
    }

    func testDraftLengthIgnoresRowPaddingOnMultilineDrafts() {
        let padding = String(repeating: " ", count: 40)
        let input = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}first line" + padding)]),
            Row(y: 2, spans: [Span(text: "" + padding)]),
            Row(y: 3, spans: [Span(text: "  third line" + padding)]),
            Row(y: 4, spans: [Span(text: rule)]),
        ], cursorY: 3)
        XCTAssertEqual(
            PromptInputClassifier.classify(input),
            .init(state: .draft, draftLength: "first line\n\n  third line".unicodeScalars.count)
        )
    }

    func testSecondOptionSelectedStillClassifiesBothSupportedChoosers() {
        // Selecting the second option leaves the first one above the selected row.
        let trust = region([
            Row(y: 7, spans: [Span(text: " one you trust? (Like your own code, a well-known open")]),
            Row(y: 8, spans: [Span(text: "")]),
            Row(y: 9, spans: [Span(text: " Security guide")]),
            Row(y: 10, spans: [Span(text: "")]),
            Row(y: 11, spans: [Span(text: "   No, exit")]),
            Row(y: 12, spans: [Span(text: " \u{276F} Yes, I trust this folder")]),
            Row(y: 13, spans: [Span(text: "")]),
            Row(y: 14, spans: [Span(text: " Enter to confirm \u{00B7} Esc to cancel")]),
        ], cursorY: 12)
        XCTAssertEqual(PromptInputClassifier.classify(trust).state, .dialog)

        let plan = region([
            Row(y: 0, spans: [Span(text: "Would you like to make this plan?")]),
            Row(y: 1, spans: [Span(text: "  Yes, implement this plan")]),
            Row(y: 2, spans: [Span(text: "\u{276F} No, keep planning")]),
            Row(y: 3, spans: [Span(text: "Enter to select \u{00B7} Esc to go back")]),
        ], cursorY: 2)
        XCTAssertEqual(PromptInputClassifier.classify(plan).state, .dialog)

        // A lone option with no partner, or a stale chooser above a live composer, stays unguarded.
        let lone = region([
            Row(y: 0, spans: [Span(text: "\u{276F} No, exit")]),
            Row(y: 1, spans: [Span(text: "Enter to confirm \u{00B7} Esc to cancel")]),
        ], cursorY: 0)
        XCTAssertEqual(PromptInputClassifier.classify(lone).state, .unknown)
    }

    func testHumanTypingAfterObservationIsNotCaughtByThePriorCheck() {
        // Documents the check-to-use limitation (not a safety promise): a person can type
        // between the observation and the paste. The guard acts on the state it was given.
        var composer = ""
        func observe() -> PromptInputState {
            PromptInputClassifier.classify(region([
                Row(y: 0, spans: [Span(text: rule)]),
                Row(y: 1, spans: [Span(text: "❯\u{00A0}" + composer)]),
                Row(y: 2, spans: [Span(text: rule)]),
            ], cursorY: 1)).state
        }

        let observed = observe()
        XCTAssertEqual(observed, .empty)

        var writes = 0
        let decision = SendInputGuard.perform(state: observed, allowUnguarded: false) {
            composer += "human typed this first"   // lands after the check, before the paste
            composer += "SENT-PAYLOAD"
            writes += 1
        }
        XCTAssertEqual(decision, .deliver(.checked))
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(composer, "human typed this firstSENT-PAYLOAD", "the earlier check cannot prevent this interleaving")

        // A fresh observation now sees the draft and refuses; nothing more is written.
        XCTAssertEqual(observe(), .draft)
        let second = SendInputGuard.perform(state: observe(), allowUnguarded: false) { writes += 1 }
        XCTAssertEqual(second, .refuse(reason: "draft"))
        XCTAssertEqual(writes, 1)
    }

    func testSoftWrappedDraftJoinsRowsWithoutLosingContent() {
        let input = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}abcdef")], softWrap: true),
            Row(y: 2, spans: [Span(text: "gh")], wrapContinuation: true),
            Row(y: 3, spans: [Span(text: rule)]),
        ], cursorY: 2)
        XCTAssertEqual(PromptInputClassifier.classify(input), .init(state: .draft, draftLength: 8))
    }

    func testRecordedClaudeQuestionAndPlanDialogsAreDialogs() {
        let question = region([
            Row(y: 0, spans: [Span(text: "Quick safety check: Is this a project you created or one you trust?")]),
            Row(y: 1, spans: [Span(text: "❯ No, exit")]),
            Row(y: 2, spans: [Span(text: "  Yes, I trust this folder")]),
            Row(y: 3, spans: [Span(text: "Enter to confirm · Esc to cancel")]),
        ], cursorY: 3)
        XCTAssertEqual(PromptInputClassifier.classify(question).state, .dialog)

        let plan = region([
            Row(y: 0, spans: [Span(text: "Would you like to make this plan?")]),
            Row(y: 1, spans: [Span(text: "❯ Yes, implement this plan")]),
            Row(y: 2, spans: [Span(text: "  No, keep planning")]),
            Row(y: 3, spans: [Span(text: "Enter to select · Esc to go back")]),
        ], cursorY: 3)
        XCTAssertEqual(PromptInputClassifier.classify(plan).state, .dialog)
    }

    func testNarrowPaneTrustChooserWithClippedHeadingIsStillADialog() {
        // Recorded from a real Claude Code trust chooser in a 50%-width area. The
        // capture window starts one row below the wrapped heading and the cursor
        // sits on the selected option, four rows above the window's last row.
        let clipped = region([
            Row(y: 7, spans: [Span(text: " one you trust? (Like your own code, a well-known open")]),
            Row(y: 8, spans: [Span(text: " source project, or work from your team). If not, take")]),
            Row(y: 9, spans: [Span(text: " a moment to review what's in this folder first.")]),
            Row(y: 10, spans: [Span(text: "")]),
            Row(y: 11, spans: [Span(text: " Claude Code'll be able to read, edit, and execute")]),
            Row(y: 12, spans: [Span(text: " files here.")]),
            Row(y: 13, spans: [Span(text: "")]),
            Row(y: 14, spans: [Span(text: " Security guide")]),
            Row(y: 15, spans: [Span(text: "")]),
            Row(y: 16, spans: [Span(text: " \u{276F} No, exit")]),
            Row(y: 17, spans: [Span(text: "   Yes, I trust this folder")]),
            Row(y: 18, spans: [Span(text: "")]),
            Row(y: 19, spans: [Span(text: " Enter to confirm \u{00B7} Esc to cancel")]),
            Row(y: 20, spans: [Span(text: "")]),
        ], cursorY: 16)
        XCTAssertEqual(PromptInputClassifier.classify(clipped).state, .dialog)
    }

    func testVisibleOldChooserAboveLiveComposerDoesNotLookLikeDialog() {
        let input = region([
            Row(y: 0, spans: [Span(text: "Quick safety check: Is this a project you created or one you trust?")]),
            Row(y: 1, spans: [Span(text: "❯ No, exit")]),
            Row(y: 2, spans: [Span(text: "  Yes, I trust this folder")]),
            Row(y: 3, spans: [Span(text: "Enter to confirm · Esc to cancel")]),
            Row(y: 4, spans: [Span(text: rule)]),
            Row(y: 5, spans: [Span(text: "❯\u{00A0} ")]),
        ], cursorY: 5)

        XCTAssertEqual(PromptInputClassifier.classify(input).state, .empty)
    }

    func testCodexEmptyPromptPlaceholderIsSuggestionAndHistoricalPromptRemainsUnknown() {
        let codex = region([
            Row(y: 0, spans: [Span(text: "› "), Span(text: "Ask Codex to do anything", faint: true)]),
        ], cursorY: 0)
        let emptyCodexPrompt = PromptRegionSnapshot(
            cursorX: 2,
            cursorY: codex.cursorY,
            cursorPendingWrap: codex.cursorPendingWrap,
            complete: codex.complete,
            rows: codex.rows,
            cells: codex.cells,
            text: codex.text
        )
        XCTAssertEqual(PromptInputClassifier.classify(emptyCodexPrompt).state, .suggestion)
        XCTAssertNil(PromptInputClassifier.composerText(emptyCodexPrompt))

        let nonFaintText = region([
            Row(y: 0, spans: [Span(text: "› "), Span(text: "Ask Codex to do anything")]),
        ], cursorY: 0)
        let editedCodexPrompt = PromptRegionSnapshot(
            cursorX: 2,
            cursorY: nonFaintText.cursorY,
            cursorPendingWrap: nonFaintText.cursorPendingWrap,
            complete: nonFaintText.complete,
            rows: nonFaintText.rows,
            cells: nonFaintText.cells,
            text: nonFaintText.text
        )
        XCTAssertEqual(PromptInputClassifier.classify(editedCodexPrompt).state, .draft)
        XCTAssertEqual(PromptInputClassifier.composerText(editedCodexPrompt), "Ask Codex to do anything")

        let codexDraft = region([
            Row(y: 0, spans: [Span(text: "› " + "first line")]),
            Row(y: 1, spans: [Span(text: "second line")]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(codexDraft).state, .draft)
        XCTAssertEqual(PromptInputClassifier.composerText(codexDraft), "first line\nsecond line")

        let codexRenderedMultiline = region([
            Row(y: 0, spans: [Span(text: "› first line")]),
            Row(y: 1, spans: [Span(text: "  second line")]),
            Row(y: 2, spans: [Span(text: "    third line")]),
        ], cursorY: 2)
        let codexBody = "first line\nsecond line\n  third line"
        XCTAssertEqual(PromptInputClassifier.classify(codexRenderedMultiline).state, .draft)
        XCTAssertEqual(PromptInputClassifier.composerText(codexRenderedMultiline), codexBody)
        XCTAssertEqual(
            PromptInputClassifier.classify(codexRenderedMultiline).draftLength,
            codexBody.unicodeScalars.count
        )
        XCTAssertEqual(
            FeedAnswerComposerCheck.compare(
                state: PromptInputClassifier.classify(codexRenderedMultiline).state,
                composer: PromptInputClassifier.composerText(codexRenderedMultiline),
                expected: codexBody
            ),
            .matches
        )

        var refusedWrites = 0
        XCTAssertEqual(
            SendInputGuard.perform(
                state: PromptInputClassifier.classify(codexRenderedMultiline).state,
                allowUnguarded: false
            ) { refusedWrites += 1 },
            .refuse(reason: "draft"),
            "a pre-existing Codex draft remains protected by the shared send guard"
        )
        XCTAssertEqual(refusedWrites, 0)

        let codexSoftWrappedSingleLine = region([
            Row(y: 0, spans: [Span(text: "› Reply with exactly C11-FEED-SINGLE-OK and ")], softWrap: true),
            Row(y: 1, spans: [Span(text: "  nothing else.")], wrapContinuation: true),
        ], cursorY: 1)
        let singleLineBody = "Reply with exactly C11-FEED-SINGLE-OK and nothing else."
        XCTAssertEqual(PromptInputClassifier.composerText(codexSoftWrappedSingleLine), singleLineBody)
        XCTAssertEqual(
            FeedAnswerComposerCheck.compare(
                state: PromptInputClassifier.classify(codexSoftWrappedSingleLine).state,
                composer: PromptInputClassifier.composerText(codexSoftWrappedSingleLine),
                expected: singleLineBody
            ),
            .matches
        )

        let transcript = region([
            Row(y: 0, spans: [Span(text: "❯ say hi in two words")]),
        ], cursorY: 0)
        XCTAssertEqual(PromptInputClassifier.classify(transcript).state, .unknown)
    }

    func testIncompleteAndClippedWrapsRemainUnknown() {
        let incomplete = region([
            Row(y: 0, spans: [Span(text: "❯\u{00A0}draft")]),
        ], cursorY: 0, complete: false)
        XCTAssertEqual(PromptInputClassifier.classify(incomplete).state, .unknown)

        let clippedWrap = region([
            Row(y: 0, spans: [Span(text: "❯\u{00A0}draft")], softWrap: true),
        ], cursorY: 0)
        XCTAssertEqual(PromptInputClassifier.classify(clippedWrap).state, .unknown)
    }

    func testOversizedRegionRemainsUnknown() {
        let input = region([Row(y: 0, spans: [Span(text: "❯\u{00A0} ")])], cursorY: 0)
        let oversized = PromptRegionSnapshot(
            cursorX: input.cursorX,
            cursorY: input.cursorY,
            cursorPendingWrap: input.cursorPendingWrap,
            complete: true,
            rows: input.rows,
            cells: Array(repeating: PromptRegionCell(textOffset: 0, textLength: 1, faint: false),
                         count: PromptInputClassifier.maxCells + 1),
            text: Data(repeating: 0x20, count: PromptInputClassifier.maxTextBytes + 1)
        )

        XCTAssertEqual(PromptInputClassifier.classify(oversized).state, .unknown)
    }

    private func region(_ rows: [Row], cursorY: Int, complete: Bool = true) -> PromptRegionSnapshot {
        var bytes = Data()
        var cells: [PromptRegionCell] = []
        var outputRows: [PromptRegionRow] = []
        var cursorX = 0

        for row in rows {
            let startCell = cells.count
            for span in row.spans {
                for scalar in span.text.unicodeScalars {
                    let encoded = String(scalar).utf8
                    let offset = bytes.count
                    bytes.append(contentsOf: encoded)
                    cells.append(PromptRegionCell(textOffset: offset, textLength: encoded.count, faint: span.faint))
                    if row.y == cursorY { cursorX += 1 }
                }
            }
            outputRows.append(PromptRegionRow(
                screenY: row.y,
                cellRange: startCell..<cells.count,
                softWrap: row.softWrap,
                wrapContinuation: row.wrapContinuation
            ))
        }

        return PromptRegionSnapshot(
            cursorX: cursorX,
            cursorY: cursorY,
            cursorPendingWrap: false,
            complete: complete,
            rows: outputRows,
            cells: cells,
            text: bytes
        )
    }
}

final class SendInputGuardTests: XCTestCase {
    func testDraftAndDialogRefuseBeforeWriterRuns() {
        var writes = 0
        for state in [PromptInputState.draft, .dialog] {
            let decision = SendInputGuard.perform(state: state, allowUnguarded: false) { writes += 1 }
            if case .refuse = decision {
                continue
            }
            XCTFail("expected refusal for \(state)")
        }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(SendInputGuard.decide(state: .draft, allowUnguarded: false), .refuse(reason: "draft"))
        XCTAssertEqual(SendInputGuard.decide(state: .dialog, allowUnguarded: false), .refuse(reason: "dialog"))
    }

    func testEmptySuggestionAndUnknownPreserveCompatibility() {
        var writes = 0
        for state in [PromptInputState.empty, .suggestion] {
            XCTAssertEqual(
                SendInputGuard.perform(state: state, allowUnguarded: false) { writes += 1 },
                .deliver(.checked)
            )
        }
        XCTAssertEqual(
            SendInputGuard.perform(state: .unknown, allowUnguarded: false) { writes += 1 },
            .deliver(.unknown)
        )
        XCTAssertEqual(writes, 3)
    }

    func testExplicitOverrideDeliversBlockedStates() {
        var writes = 0
        for state in [PromptInputState.draft, .dialog] {
            XCTAssertEqual(
                SendInputGuard.perform(state: state, allowUnguarded: true) { writes += 1 },
                .deliver(.overridden)
            )
        }
        XCTAssertEqual(writes, 2)
    }

    func testReplacedTabIsUnavailableAndNeverReachesWriter() {
        let workspace = PromptInputTargetIdentity()
        let originalTab = PromptInputTargetIdentity()
        let replacementTab = PromptInputTargetIdentity()
        let sameWorkspace = SendInputGuard.targetIsCurrent(
            expectedWorkspace: workspace,
            currentWorkspaces: [workspace],
            expectedTab: originalTab,
            currentTab: replacementTab
        )

        var writes = 0
        let decision = SendInputGuard.perform(
            state: .empty,
            allowUnguarded: false,
            targetAvailable: sameWorkspace
        ) { writes += 1 }
        XCTAssertFalse(sameWorkspace)
        XCTAssertEqual(decision, .unavailable)
        XCTAssertEqual(writes, 0)
    }
}

final class FeedAnswerSafetyTests: XCTestCase {
    func testEligibilityRequiresCurrentFlagOrCompletedTurnAndExactRowIdentity() throws {
        let workspaceID = UUID()
        let tabID = UUID()
        let owner = JournalOwner(tabID: tabID, agentKind: "claude", sessionID: "fixture-session")
        let epoch = Date(timeIntervalSince1970: 1_000)
        let flagSnapshot = snapshot(owner: owner, workspaceID: workspaceID, phase: .working, sequence: 41)
        let attention = TabAttentionSnapshot(
            workspaceId: workspaceID,
            surfaceId: tabID,
            flagReason: "fixture blocker",
            flagRaisedAt: epoch,
            suppressed: false
        )
        let projectedRow = try row(for: flagSnapshot, attention: attention)

        let identity = try XCTUnwrap(FeedAnswerEligibility.capture(
            workspaceID: workspaceID,
            tabID: tabID,
            targetWorkspaceID: workspaceID,
            owner: owner,
            snapshot: flagSnapshot,
            attention: attention,
            projectedRow: projectedRow
        ))
        XCTAssertEqual(identity.startKind, .flag)
        XCTAssertEqual(identity.flagEpoch, epoch)
        XCTAssertFalse(FeedAnswerEligibility.stillEligible(
            identity,
            targetWorkspaceID: workspaceID,
            owner: owner,
            snapshot: snapshot(owner: owner, workspaceID: workspaceID, phase: .working, sequence: 42),
            attention: attention
        ), "a later journal row must not inherit this answer")

        let wrongOwner = JournalOwner(tabID: tabID, agentKind: "claude", sessionID: "replacement-session")
        XCTAssertNil(FeedAnswerEligibility.capture(
            workspaceID: workspaceID,
            tabID: tabID,
            targetWorkspaceID: workspaceID,
            owner: wrongOwner,
            snapshot: flagSnapshot,
            attention: attention,
            projectedRow: projectedRow
        ))
        XCTAssertNil(FeedAnswerEligibility.capture(
            workspaceID: workspaceID,
            tabID: tabID,
            targetWorkspaceID: workspaceID,
            owner: owner,
            snapshot: flagSnapshot,
            attention: attention,
            projectedRow: FeedAnswerProjectionRow(
                row: projectedRow.row,
                owner: owner,
                sequence: flagSnapshot.lastSequence + 1,
                askEventID: projectedRow.askEventID
            )
        ))

        let blockedSnapshot = snapshot(
            owner: owner,
            workspaceID: workspaceID,
            phase: .blocked,
            reason: .question,
            sequence: 43
        )
        let blockedRow = try row(for: blockedSnapshot, attention: attention)
        XCTAssertNil(FeedAnswerEligibility.capture(
            workspaceID: workspaceID,
            tabID: tabID,
            targetWorkspaceID: workspaceID,
            owner: owner,
            snapshot: blockedSnapshot,
            attention: attention,
            projectedRow: blockedRow
        ), "an ask remains blocking even when its tab is flagged")

        let completed = snapshot(
            owner: owner,
            workspaceID: workspaceID,
            phase: .idle,
            sequence: 44,
            turnOutcome: "completed"
        )
        let completedRow = try row(for: completed, attention: nil)
        let turnIdentity = try XCTUnwrap(FeedAnswerEligibility.capture(
            workspaceID: workspaceID,
            tabID: tabID,
            targetWorkspaceID: workspaceID,
            owner: owner,
            snapshot: completed,
            attention: TabAttentionSnapshot(
                workspaceId: workspaceID,
                surfaceId: tabID,
                flagReason: nil,
                flagRaisedAt: nil,
                suppressed: false
            ),
            projectedRow: completedRow
        ))
        XCTAssertEqual(turnIdentity.startKind, .turnEnd)
        XCTAssertNil(turnIdentity.flagEpoch)
    }

    func testOnlyPositiveNativeHandoffCanLowerFlag() {
        var lowerCalls = 0
        XCTAssertEqual(
            FeedAnswerHandoff.outcome(nativeHandoff: false, startKind: .flag) {
                lowerCalls += 1
                return .lowered
            },
            .submitUnconfirmed
        )
        XCTAssertEqual(lowerCalls, 0)

        XCTAssertEqual(
            FeedAnswerHandoff.outcome(nativeHandoff: true, startKind: .flag) {
                lowerCalls += 1
                return .lowered
            },
            .submitted(flagLowered: true, flagEpoch: nil)
        )
        XCTAssertEqual(lowerCalls, 1)

        XCTAssertEqual(
            FeedAnswerHandoff.outcome(nativeHandoff: true, startKind: .turnEnd) {
                lowerCalls += 1
                return .lowered
            },
            .submitted(flagLowered: false, flagEpoch: nil)
        )
        XCTAssertEqual(lowerCalls, 1)
    }

    func testComposerCheckSeparatesUnseenPasteFromChangedPrompt() {
        let body = "FEED-ANSWER-FIXTURE"
        XCTAssertEqual(FeedAnswerComposerCheck.compare(state: .draft, composer: body, expected: body), .matches)
        XCTAssertEqual(FeedAnswerComposerCheck.compare(state: .empty, composer: nil, expected: body), .notVisible)
        XCTAssertEqual(FeedAnswerComposerCheck.compare(state: .suggestion, composer: nil, expected: body), .notVisible)
        XCTAssertEqual(FeedAnswerComposerCheck.compare(state: .draft, composer: "FEED-ANSWER", expected: body), .notVisible)
        XCTAssertEqual(FeedAnswerComposerCheck.compare(state: .draft, composer: "operator text", expected: body), .changed)
        XCTAssertEqual(FeedAnswerComposerCheck.compare(state: .dialog, composer: nil, expected: body), .changed)
        XCTAssertEqual(FeedAnswerComposerCheck.compare(state: .unknown, composer: nil, expected: body), .changed)
    }

    func testTimeoutCancelsPendingAnswerBeforeDelayedCommitRuns() {
        var effects = 0
        let gate = FailClosedCommitGate<FeedAnswerSubmitOutcome> {
            effects += 1
            return .submitted(flagLowered: true, flagEpoch: nil)
        }

        XCTAssertNil(gate.wait(timeout: 0.001))
        gate.enqueue { work in work() }
        XCTAssertEqual(effects, 0, "a cancelled paste-settle callback must not submit or lower")
    }

    #if DEBUG
    func testCloseDuringHeldPostPasteReturnFailsClosedWithUnsafeRetryAndNoLower() throws {
        let tabID = UUID()
        let replacementTabID = UUID()
        XCTAssertTrue(FeedAnswerDebugHold.shared.arm(tabID: tabID, milliseconds: 900))
        defer { FeedAnswerDebugHold.shared.clear(tabID: tabID) }
        XCTAssertNil(FeedAnswerDebugHold.shared.consume(tabID: replacementTabID))
        XCTAssertEqual(FeedAnswerDebugHold.shared.consume(tabID: tabID), 900)

        let state = FeedAnswerRaceState()
        let gate = FailClosedCommitGate<FeedAnswerSubmitOutcome> {
            if let failure = FeedAnswerPreReturnCheck.outcome(
                targetIsCurrent: state.targetIsCurrent,
                rowIsCurrent: true,
                operatorInputUnchanged: true,
                composer: .matches
            ) {
                return failure
            }
            return FeedAnswerHandoff.outcome(
                nativeHandoff: state.sendReturn(),
                startKind: .flag
            ) {
                state.lowerFlag()
            }
        }

        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        gate.enqueue { work in
            DispatchQueue.global(qos: .utility).async {
                held.signal()
                _ = release.wait(timeout: .now() + 2)
                work()
            }
        }
        XCTAssertEqual(held.wait(timeout: .now() + 1), .success)
        state.closeTarget()
        release.signal()

        let outcome = try XCTUnwrap(gate.wait(timeout: 1))
        XCTAssertEqual(outcome, .targetLost)
        XCTAssertEqual(
            FeedAnswerFailureDisposition.make(for: outcome),
            FeedAnswerFailureDisposition(code: "target_lost", retry: "unsafe")
        )
        XCTAssertEqual(state.effects.returns, 0)
        XCTAssertEqual(state.effects.flagLowers, 0)
    }
    #endif

    func testReplacedFlagEpochCannotBeLoweredByDelayedAnswer() throws {
        let store = TabMetadataStore.shared
        let workspaceID = UUID()
        let tabID = UUID()
        let originalEpoch = Date(timeIntervalSince1970: 2_000)
        let replacementEpoch = Date(timeIntervalSince1970: 3_000)
        defer { store.removeSurface(workspaceId: workspaceID, surfaceId: tabID) }

        _ = try store.mutateAttention(
            workspaceId: workspaceID,
            surfaceId: tabID,
            flag: .raise("original"),
            now: originalEpoch
        )
        _ = try store.mutateAttention(workspaceId: workspaceID, surfaceId: tabID, flag: .lower)
        _ = try store.mutateAttention(
            workspaceId: workspaceID,
            surfaceId: tabID,
            flag: .raise("replacement"),
            now: replacementEpoch
        )

        let staleLower = try store.mutateAttention(
            workspaceId: workspaceID,
            surfaceId: tabID,
            flag: .lower,
            expectedFlagEpoch: originalEpoch
        )
        XCTAssertEqual(staleLower.result.applied[MetadataKey.flag], false)
        XCTAssertEqual(staleLower.result.reasons[MetadataKey.flag], "epoch_changed")
        XCTAssertEqual(staleLower.after.flagReason, "replacement")
        XCTAssertEqual(staleLower.after.flagRaisedAt, replacementEpoch)
    }

    private func snapshot(
        owner: JournalOwner,
        workspaceID: UUID,
        phase: JournalPhase,
        reason: JournalReason? = nil,
        sequence: Int64,
        turnOutcome: String? = nil
    ) -> JournalSnapshot {
        JournalSnapshot(
            owner: owner,
            workspaceID: workspaceID,
            phase: phase,
            reason: reason,
            requestID: reason == nil ? nil : "fixture-request",
            turnOutcome: turnOutcome,
            appInstanceID: UUID(),
            lastSequence: sequence,
            confirmation: .confirmed,
            connection: .live
        )
    }

    private func row(
        for snapshot: JournalSnapshot,
        attention: TabAttentionSnapshot?
    ) throws -> FeedAnswerProjectionRow {
        let attentionFacts = attention.map { value in
            [FeedAttentionFact(
                workspaceID: value.workspaceId,
                tabID: value.surfaceId,
                flagReason: value.flagReason,
                flagRaisedAtMs: value.flagRaisedAt.map { Int64($0.timeIntervalSince1970 * 1_000) },
                flagCallerTabID: value.flagCallerTabId,
                suppressed: value.suppressed
            )]
        } ?? []
        let projected = try XCTUnwrap(FeedProjector.project(
            journalRows: [snapshot],
            attention: attentionFacts,
            notes: [:],
            scope: .all
        ).first)
        return FeedAnswerProjectionRow(
            row: projected,
            owner: snapshot.owner,
            sequence: snapshot.lastSequence,
            askEventID: UUID()
        )
    }
}

private final class FeedAnswerRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true
    private var returnCount = 0
    private var flagLowerCount = 0

    var targetIsCurrent: Bool {
        lock.lock(); defer { lock.unlock() }
        return isOpen
    }

    var effects: (returns: Int, flagLowers: Int) {
        lock.lock(); defer { lock.unlock() }
        return (returnCount, flagLowerCount)
    }

    func closeTarget() {
        lock.lock(); isOpen = false; lock.unlock()
    }

    func sendReturn() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return false }
        returnCount += 1
        return true
    }

    func lowerFlag() -> FeedAnswerFlagLowerOutcome {
        lock.lock(); defer { lock.unlock() }
        flagLowerCount += 1
        return .lowered
    }
}
