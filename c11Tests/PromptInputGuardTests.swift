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

    func testGrokEmptyBoxIsAnEmptyPrompt() {
        let top = "╭" + String(repeating: "─", count: 20) + "╮"
        let prompt = "│ ❯" + String(repeating: " ", count: 16) + "│"
        let bottom = "╰──────── Grok 4.7 · always-approve ─╯"
        let input = region([
            Row(y: 0, spans: [Span(text: top)]),
            Row(y: 1, spans: [Span(text: prompt)]),
            Row(y: 2, spans: [Span(text: bottom)]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(input, harness: "grok"), .init(state: .empty, draftLength: nil))
    }

    func testGrokDraftStopsAtTheBoxFooter() {
        let top = "╭" + String(repeating: "─", count: 20) + "╮"
        let prompt = "│ ❯ hello │"
        let bottom = "╰──────── Grok 4.7 · always-approve ─╯"
        let input = region([
            Row(y: 0, spans: [Span(text: top)]),
            Row(y: 1, spans: [Span(text: prompt)]),
            Row(y: 2, spans: [Span(text: bottom)]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(input, harness: "grok").state, .draft)
        XCTAssertEqual(PromptInputClassifier.composerText(input, harness: "grok"), "hello")
    }

    func testEmptyAndFaintSuggestionAreDistinct() {
        let empty = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0} ")]),
            Row(y: 2, spans: [Span(text: rule)]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(empty, harness: "claude-code"), .init(state: .empty, draftLength: nil))

        let suggestion = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0} "), Span(text: "Try \"fix lint errors\"", faint: true)]),
            Row(y: 2, spans: [Span(text: rule)]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(suggestion, harness: "claude-code"), .init(state: .suggestion, draftLength: nil))
    }

    func testDraftReportsOnlyLengthAndNeverPromptText() throws {
        let sentinel = "NEVER_EXPOSE_PROMPT_9F31"
        let input = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}"), Span(text: sentinel)]),
            Row(y: 2, spans: [Span(text: rule)]),
        ], cursorY: 1)

        let classification = PromptInputClassifier.classify(input, harness: "claude-code")
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
        XCTAssertEqual(PromptInputClassifier.composerText(singleLine, harness: "claude-code"), body)

        let multiline = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}first line")]),
            Row(y: 2, spans: [Span(text: "")]),
            Row(y: 3, spans: [Span(text: "  third line")]),
            Row(y: 4, spans: [Span(text: rule)]),
        ], cursorY: 3)
        XCTAssertEqual(PromptInputClassifier.composerText(multiline, harness: "claude-code"), "first line\n\n  third line")

        let suggestion = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0} "), Span(text: "suggested text", faint: true)]),
            Row(y: 2, spans: [Span(text: rule)]),
        ], cursorY: 1)
        XCTAssertNil(PromptInputClassifier.composerText(suggestion, harness: "claude-code"))

        let dialog = region([
            Row(y: 0, spans: [Span(text: "Would you like to make this plan?")]),
            Row(y: 1, spans: [Span(text: "❯ Yes, implement this plan")]),
            Row(y: 2, spans: [Span(text: "  No, keep planning")]),
            Row(y: 3, spans: [Span(text: "Enter to select · Esc to go back")]),
        ], cursorY: 3)
        XCTAssertNil(PromptInputClassifier.composerText(dialog, harness: "claude-code"))

        let unknown = region([Row(y: 0, spans: [Span(text: "ordinary terminal output")])], cursorY: 0)
        XCTAssertNil(PromptInputClassifier.composerText(unknown, harness: "claude-code"))
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
        XCTAssertEqual(PromptInputClassifier.classify(input, harness: "claude-code"), .init(state: .draft, draftLength: expectedLength))
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
            PromptInputClassifier.classify(leading, harness: "claude-code"),
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
            PromptInputClassifier.classify(embedded, harness: "claude-code"),
            .init(state: .draft, draftLength: "first\n\n  third".unicodeScalars.count)
        )

        // A rule above the cursor row means the typed row was never reached: unknown, not empty.
        let ruleBeforeCursor = region([
            Row(y: 0, spans: [Span(text: "❯\u{00A0}")]),
            Row(y: 1, spans: [Span(text: rule)]),
            Row(y: 2, spans: [Span(text: "  typed below a rule")]),
        ], cursorY: 2)
        XCTAssertEqual(PromptInputClassifier.classify(ruleBeforeCursor, harness: "claude-code").state, .unknown)
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
            PromptInputClassifier.classify(input, harness: "claude-code"),
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
        XCTAssertEqual(PromptInputClassifier.classify(trust, harness: "claude-code").state, .dialog)

        let plan = region([
            Row(y: 0, spans: [Span(text: "Would you like to make this plan?")]),
            Row(y: 1, spans: [Span(text: "  Yes, implement this plan")]),
            Row(y: 2, spans: [Span(text: "\u{276F} No, keep planning")]),
            Row(y: 3, spans: [Span(text: "Enter to select \u{00B7} Esc to go back")]),
        ], cursorY: 2)
        XCTAssertEqual(PromptInputClassifier.classify(plan, harness: "claude-code").state, .dialog)

        // A lone option with no partner, or a stale chooser above a live composer, stays unguarded.
        let lone = region([
            Row(y: 0, spans: [Span(text: "\u{276F} No, exit")]),
            Row(y: 1, spans: [Span(text: "Enter to confirm \u{00B7} Esc to cancel")]),
        ], cursorY: 0)
        XCTAssertEqual(PromptInputClassifier.classify(lone, harness: "claude-code").state, .unknown)
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
            ], cursorY: 1), harness: "claude-code").state
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
        XCTAssertEqual(PromptInputClassifier.classify(input, harness: "claude-code"), .init(state: .draft, draftLength: 8))
    }

    func testRecordedClaudeQuestionAndPlanDialogsAreDialogs() {
        let question = region([
            Row(y: 0, spans: [Span(text: "Quick safety check: Is this a project you created or one you trust?")]),
            Row(y: 1, spans: [Span(text: "❯ No, exit")]),
            Row(y: 2, spans: [Span(text: "  Yes, I trust this folder")]),
            Row(y: 3, spans: [Span(text: "Enter to confirm · Esc to cancel")]),
        ], cursorY: 3)
        XCTAssertEqual(PromptInputClassifier.classify(question, harness: "claude-code").state, .dialog)

        let plan = region([
            Row(y: 0, spans: [Span(text: "Would you like to make this plan?")]),
            Row(y: 1, spans: [Span(text: "❯ Yes, implement this plan")]),
            Row(y: 2, spans: [Span(text: "  No, keep planning")]),
            Row(y: 3, spans: [Span(text: "Enter to select · Esc to go back")]),
        ], cursorY: 3)
        XCTAssertEqual(PromptInputClassifier.classify(plan, harness: "claude-code").state, .dialog)
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
        XCTAssertEqual(PromptInputClassifier.classify(clipped, harness: "claude-code").state, .dialog)
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

        XCTAssertEqual(PromptInputClassifier.classify(input, harness: "claude-code").state, .empty)
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
        XCTAssertEqual(PromptInputClassifier.classify(emptyCodexPrompt, harness: "codex").state, .suggestion)
        XCTAssertNil(PromptInputClassifier.composerText(emptyCodexPrompt, harness: "codex"))

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
        XCTAssertEqual(PromptInputClassifier.classify(editedCodexPrompt, harness: "codex").state, .draft)
        XCTAssertEqual(PromptInputClassifier.composerText(editedCodexPrompt, harness: "codex"), "Ask Codex to do anything")

        let codexDraft = region([
            Row(y: 0, spans: [Span(text: "› " + "first line")]),
            Row(y: 1, spans: [Span(text: "second line")]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(codexDraft, harness: "codex").state, .draft)
        XCTAssertEqual(PromptInputClassifier.composerText(codexDraft, harness: "codex"), "first line\nsecond line")

        let codexRenderedMultiline = region([
            Row(y: 0, spans: [Span(text: "› first line")]),
            Row(y: 1, spans: [Span(text: "  second line")]),
            Row(y: 2, spans: [Span(text: "    third line")]),
        ], cursorY: 2)
        let codexBody = "first line\nsecond line\n  third line"
        XCTAssertEqual(PromptInputClassifier.classify(codexRenderedMultiline, harness: "codex").state, .draft)
        XCTAssertEqual(PromptInputClassifier.composerText(codexRenderedMultiline, harness: "codex"), codexBody)
        XCTAssertEqual(
            PromptInputClassifier.classify(codexRenderedMultiline, harness: "codex").draftLength,
            codexBody.unicodeScalars.count
        )
        XCTAssertEqual(
            FeedAnswerComposerCheck.compare(
                state: PromptInputClassifier.classify(codexRenderedMultiline, harness: "codex").state,
                composer: PromptInputClassifier.composerText(codexRenderedMultiline, harness: "codex"),
                expected: codexBody
            ),
            .matches
        )

        var refusedWrites = 0
        XCTAssertEqual(
            SendInputGuard.perform(
                state: PromptInputClassifier.classify(codexRenderedMultiline, harness: "codex").state,
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
        XCTAssertEqual(PromptInputClassifier.composerText(codexSoftWrappedSingleLine, harness: "codex"), singleLineBody)
        XCTAssertEqual(
            FeedAnswerComposerCheck.compare(
                state: PromptInputClassifier.classify(codexSoftWrappedSingleLine, harness: "codex").state,
                composer: PromptInputClassifier.composerText(codexSoftWrappedSingleLine, harness: "codex"),
                expected: singleLineBody
            ),
            .matches
        )

        let codexMultilineWithWrappedFirstRow = region([
            Row(y: 0, spans: [Span(text: "› Return these two lines exactly and nothing ")], softWrap: true),
            Row(y: 1, spans: [Span(text: "  else:")], wrapContinuation: true),
            Row(y: 2, spans: [Span(text: "  C11-268-MULTILINE-ONE")]),
            Row(y: 3, spans: [Span(text: "  C11-268-MULTILINE-TWO")]),
        ], cursorY: 3)
        let multilineBody = "Return these two lines exactly and nothing else:\nC11-268-MULTILINE-ONE\nC11-268-MULTILINE-TWO"
        XCTAssertEqual(PromptInputClassifier.composerText(codexMultilineWithWrappedFirstRow, harness: "codex"), multilineBody)
        XCTAssertEqual(
            FeedAnswerComposerCheck.compare(
                state: PromptInputClassifier.classify(codexMultilineWithWrappedFirstRow, harness: "codex").state,
                composer: PromptInputClassifier.composerText(codexMultilineWithWrappedFirstRow, harness: "codex"),
                expected: multilineBody
            ),
            .matches
        )

        let transcript = region([
            Row(y: 0, spans: [Span(text: "❯ say hi in two words")]),
        ], cursorY: 0)
        XCTAssertEqual(PromptInputClassifier.classify(transcript, harness: "codex").state, .unknown)
    }

    func testIncompleteAndClippedWrapsRemainUnknown() {
        let incomplete = region([
            Row(y: 0, spans: [Span(text: "❯\u{00A0}draft")]),
        ], cursorY: 0, complete: false)
        XCTAssertEqual(PromptInputClassifier.classify(incomplete, harness: "claude-code").state, .unknown)

        let clippedWrap = region([
            Row(y: 0, spans: [Span(text: "❯\u{00A0}draft")], softWrap: true),
        ], cursorY: 0)
        XCTAssertEqual(PromptInputClassifier.classify(clippedWrap, harness: "claude-code").state, .unknown)
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

        XCTAssertEqual(PromptInputClassifier.classify(oversized, harness: "claude-code").state, .unknown)
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
        let originalPanel = PromptInputTargetIdentity()
        let replacementPanel = PromptInputTargetIdentity()
        let sameWorkspace = SendInputGuard.targetIsCurrent(
            expectedWorkspace: workspace,
            currentWorkspaces: [workspace],
            expectedPanel: originalPanel,
            currentPanel: replacementPanel
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
    func testFeedAnswerAddsPasteSettleBeforeGuardedReturn() {
        XCTAssertEqual(FeedAnswerTiming.returnDelayMilliseconds(baseDelayMs: 200, debugHoldMs: 0), 550)
        XCTAssertEqual(FeedAnswerTiming.returnDelayMilliseconds(baseDelayMs: 200, debugHoldMs: 150), 700)
    }

    func testEligibilityRequiresCurrentFlagOrCompletedTurnAndExactRowIdentity() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let owner = JournalOwner(panelID: panelID, agentKind: "claude", sessionID: "fixture-session")
        let epoch = Date(timeIntervalSince1970: 1_000)
        let flagSnapshot = snapshot(owner: owner, workspaceID: workspaceID, phase: .working, sequence: 41)
        let attention = PanelAttentionSnapshot(
            workspaceId: workspaceID,
            surfaceId: panelID,
            flagReason: "fixture blocker",
            flagRaisedAt: epoch,
            suppressed: false
        )
        let projectedRow = try row(for: flagSnapshot, attention: attention)

        let identity = try XCTUnwrap(FeedAnswerEligibility.capture(
            workspaceID: workspaceID,
            panelID: panelID,
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

        let wrongOwner = JournalOwner(panelID: panelID, agentKind: "claude", sessionID: "replacement-session")
        XCTAssertNil(FeedAnswerEligibility.capture(
            workspaceID: workspaceID,
            panelID: panelID,
            targetWorkspaceID: workspaceID,
            owner: wrongOwner,
            snapshot: flagSnapshot,
            attention: attention,
            projectedRow: projectedRow
        ))
        XCTAssertNil(FeedAnswerEligibility.capture(
            workspaceID: workspaceID,
            panelID: panelID,
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
            panelID: panelID,
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
            panelID: panelID,
            targetWorkspaceID: workspaceID,
            owner: owner,
            snapshot: completed,
            attention: PanelAttentionSnapshot(
                workspaceId: workspaceID,
                surfaceId: panelID,
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
        let wrapped = "c11 mail waiting: run c11 mailbox\n  recv --ack"
        let doorbell = "c11 mail waiting: run c11 mailbox recv --ack"
        XCTAssertEqual(FeedAnswerComposerCheck.compare(state: .draft, composer: wrapped, expected: doorbell), .matches)
        XCTAssertEqual(
            FeedAnswerComposerCheck.compare(state: .draft, composer: wrapped + " extra", expected: doorbell),
            .changed
        )
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
        let panelID = UUID()
        let replacementPanelID = UUID()
        XCTAssertTrue(FeedAnswerDebugHold.shared.arm(panelID: panelID, milliseconds: 900))
        defer { FeedAnswerDebugHold.shared.clear(panelID: panelID) }
        XCTAssertNil(FeedAnswerDebugHold.shared.consume(panelID: replacementPanelID))
        XCTAssertEqual(FeedAnswerDebugHold.shared.consume(panelID: panelID), 900)

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
        let store = PanelMetadataStore.shared
        let workspaceID = UUID()
        let panelID = UUID()
        let originalEpoch = Date(timeIntervalSince1970: 2_000)
        let replacementEpoch = Date(timeIntervalSince1970: 3_000)
        defer { store.removeSurface(workspaceId: workspaceID, surfaceId: panelID) }

        _ = try store.mutateAttention(
            workspaceId: workspaceID,
            surfaceId: panelID,
            flag: .raise("original"),
            now: originalEpoch
        )
        _ = try store.mutateAttention(workspaceId: workspaceID, surfaceId: panelID, flag: .lower)
        _ = try store.mutateAttention(
            workspaceId: workspaceID,
            surfaceId: panelID,
            flag: .raise("replacement"),
            now: replacementEpoch
        )

        let staleLower = try store.mutateAttention(
            workspaceId: workspaceID,
            surfaceId: panelID,
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
        attention: PanelAttentionSnapshot?
    ) throws -> FeedAnswerProjectionRow {
        let attentionFacts = attention.map { value in
            [FeedAttentionFact(
                workspaceID: value.workspaceId,
                panelID: value.surfaceId,
                flagReason: value.flagReason,
                flagRaisedAtMs: value.flagRaisedAt.map { Int64($0.timeIntervalSince1970 * 1_000) },
                flagCallerPanelID: value.flagCallerPanelId,
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

extension PromptInputClassifierTests {
    func testReviewProbeOpenCodeIdleComposerAdmitsDoorbell() {
        let rows = [
            Row(y: 0, spans: [Span(text: "  ┃")]),
            Row(y: 1, spans: [Span(text: "  ┃  "), Span(text: "Ask anything… \"Fix a TODO in the codebase\"", faint: true)]),
            Row(y: 2, spans: [Span(text: "  ┃")]),
            Row(y: 3, spans: [Span(text: "  ┃  K3-256k · K3-256k Kimi For Coding · high")]),
            Row(y: 4, spans: [Span(text: "  ╹" + String(repeating: "▀", count: 60))]),
        ]
        let state = PromptInputClassifier.classify(region(rows, cursorY: 1), harness: "opencode").state
        var input = MailboxDoorbell.Input()
        input.prompt = state
        XCTAssertEqual(MailboxDoorbell.decide(input), .ring, "OpenCode idle composer reads \(state)")
    }

    func testReviewProbeOpenCodeDraftStaysADraft() {
        let rows = [
            Row(y: 0, spans: [Span(text: "  ┃")]),
            Row(y: 1, spans: [Span(text: "  ┃  fix the todo")]),
            Row(y: 2, spans: [Span(text: "  ┃")]),
            Row(y: 3, spans: [Span(text: "  ┃  K3-256k · K3-256k Kimi For Coding · high")]),
            Row(y: 4, spans: [Span(text: "  ╹" + String(repeating: "▀", count: 60))]),
        ]
        let input = region(rows, cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(input, harness: "opencode").state, .draft)
        XCTAssertEqual(PromptInputClassifier.composerText(input, harness: "opencode"), "fix the todo")
        var decision = MailboxDoorbell.Input()
        decision.prompt = .draft
        XCTAssertEqual(MailboxDoorbell.decide(decision), .skip(reason: "draft"))
    }

    /// Live OpenCode 1.18.30. The placeholder is not faint in the prompt capture.
    func testReviewProbeOpenCodePlaceholderWithoutFaintAdmitsDoorbell() {
        let rows = [
            Row(y: 0, spans: [Span(text: "            ┃")]),
            Row(y: 1, spans: [Span(text: "            ┃  Ask anything… \"What is the tech stack of this project?\"")]),
            Row(y: 2, spans: [Span(text: "            ┃")]),
            Row(y: 3, spans: [Span(text: "            ┃  K3-256k · K3-256k Kimi For Coding · high")]),
            Row(y: 4, spans: [Span(text: "            ╹" + String(repeating: "▀", count: 40))]),
        ]
        let input = region(rows, cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(input, harness: "opencode").state, .suggestion)
        var decision = MailboxDoorbell.Input()
        decision.prompt = PromptInputClassifier.classify(input, harness: "opencode").state
        XCTAssertEqual(MailboxDoorbell.decide(decision), .ring)

        let typed = region([
            Row(y: 0, spans: [Span(text: "  ┃")]),
            Row(y: 1, spans: [Span(text: "  ┃  Ask anything else")]),
            Row(y: 2, spans: [Span(text: "  ┃")]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(typed, harness: "opencode").state, .draft)
    }

    func testReviewProbePiIdleComposerAdmitsDoorbell() {
        let rule = String(repeating: "─", count: 69)
        let rows = [
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: " ")]),
            Row(y: 2, spans: [Span(text: rule)]),
        ]
        let state = PromptInputClassifier.classify(region(rows, cursorY: 1), harness: "pi").state
        var input = MailboxDoorbell.Input()
        input.prompt = state
        XCTAssertEqual(MailboxDoorbell.decide(input), .ring, "Pi idle composer reads \(state)")
    }

    func testReviewProbePiDraftStaysADraft() {
        let rule = String(repeating: "─", count: 69)
        let rows = [
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "fix the todo")]),
            Row(y: 2, spans: [Span(text: rule)]),
        ]
        let input = region(rows, cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(input, harness: "pi").state, .draft)
        XCTAssertEqual(PromptInputClassifier.composerText(input, harness: "pi"), "fix the todo")
    }

    /// OpenCode 1.18.30. The cursor sits on a blank ┃ row under a typed line.
    /// That draft is not an open prompt.
    func testRV394BOpenCodeMultiLineDraftIsNotAnOpenPrompt() {
        let rows = [
            Row(y: 0, spans: [Span(text: "  ┃")]),
            Row(y: 1, spans: [Span(text: "  ┃  first line of my draft")]),
            Row(y: 2, spans: [Span(text: "  ┃  ")]),
            Row(y: 3, spans: [Span(text: "  ┃")]),
            Row(y: 4, spans: [Span(text: "  ┃  K3-256k · K3-256k Kimi For Coding · high")]),
            Row(y: 5, spans: [Span(text: "  ╹" + String(repeating: "▀", count: 60))]),
        ]
        let state = PromptInputClassifier.classify(region(rows, cursorY: 2), harness: "opencode").state
        XCTAssertFalse(
            FeedAnswerPromptCommit.admits(state),
            "an OpenCode multi-line draft reads \(state); the doorbell would be typed into it"
        )
    }

    /// A narrow OpenCode panel wraps the invitation. The joined composer submits.
    func testRV394BOpenCodeWrappedInvitationSubmits() {
        let rows = [
            Row(y: 0, spans: [Span(text: "  ┃")]),
            Row(y: 1, spans: [Span(text: "  ┃  c11 mail waiting: run c11 mailbox")]),
            Row(y: 2, spans: [Span(text: "  ┃  recv --ack")]),
            Row(y: 3, spans: [Span(text: "  ┃")]),
            Row(y: 4, spans: [Span(text: "  ┃  K3-256k · K3-256k Kimi For Coding · high")]),
            Row(y: 5, spans: [Span(text: "  ╹" + String(repeating: "▀", count: 55))]),
        ]
        let input = region(rows, cursorY: 2)
        let state = PromptInputClassifier.classify(input, harness: "opencode").state
        let composer = state == .draft ? PromptInputClassifier.composerText(input, harness: "opencode") : nil
        let outcome = MailboxDoorbellSequence.preReturn(
            rowIsCurrent: true, operatorInputUnchanged: true,
            agentOwnsTerminal: true, captured: true,
            prompt: state, composer: composer
        )
        XCTAssertNil(outcome, "wrapped OpenCode invitation reads \(state) composer=\(composer ?? "nil")")
    }

    /// Pi at 30 columns wraps the invitation onto two rows between the rules.
    func testRV394BPiWrappedInvitationSubmits() {
        let rule = String(repeating: "─", count: 30)
        let rows = [
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "c11 mail waiting: run c11 ")]),
            Row(y: 2, spans: [Span(text: "mailbox recv --ack")]),
            Row(y: 3, spans: [Span(text: rule)]),
        ]
        let input = region(rows, cursorY: 2)
        let state = PromptInputClassifier.classify(input, harness: "pi").state
        let composer = state == .draft ? PromptInputClassifier.composerText(input, harness: "pi") : nil
        let outcome = MailboxDoorbellSequence.preReturn(
            rowIsCurrent: true, operatorInputUnchanged: true,
            agentOwnsTerminal: true, captured: true,
            prompt: state, composer: composer
        )
        XCTAssertNil(outcome, "wrapped Pi invitation reads \(state) composer=\(composer ?? "nil")")
    }

    /// A Pi draft that spans two rows, with the cursor on the blank one, stays a draft.
    func testRV394BPiMultiLineDraftIsNotAnOpenPrompt() {
        let rule = String(repeating: "─", count: 60)
        let rows = [
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "first line of my draft")]),
            Row(y: 2, spans: [Span(text: " ")]),
            Row(y: 3, spans: [Span(text: rule)]),
        ]
        let input = region(rows, cursorY: 2)
        let state = PromptInputClassifier.classify(input, harness: "pi").state
        XCTAssertFalse(
            FeedAnswerPromptCommit.admits(state),
            "a Pi multi-line draft reads \(state); the doorbell would be typed into it"
        )
        XCTAssertEqual(
            PromptInputClassifier.composerText(input, harness: "pi"),
            "first line of my draft"
        )
    }

    /// A Claude draft that ends on an indented rule is not Pi's empty composer.
    func testR1VerifyClaudeDraftEndingInARuleRowIsNotEmpty() {
        let rows = [
            Row(y: 0, spans: [Span(text: liveRule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}notes:")]),
            Row(y: 2, spans: [Span(text: "  ────────────")]),
            Row(y: 3, spans: [Span(text: "  ")]),
            Row(y: 4, spans: [Span(text: liveRule)]),
        ]
        let state = PromptInputClassifier.classify(region(rows, cursorY: 3), harness: "claude-code").state
        XCTAssertFalse(FeedAnswerPromptCommit.admits(state), "Claude draft ending in a rule row reads \(state)")
        var input = MailboxDoorbell.Input()
        input.prompt = state
        XCTAssertNotEqual(MailboxDoorbell.decide(input), .ring)
    }

    func testR1VerifyDoorbellAfterClaudeRuleDraftIsNotSubmitted() {
        let rows = [
            Row(y: 0, spans: [Span(text: liveRule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}notes:")]),
            Row(y: 2, spans: [Span(text: "  ────────────")]),
            Row(y: 3, spans: [Span(text: "  " + MailboxDoorbell.text)]),
            Row(y: 4, spans: [Span(text: liveRule)]),
        ]
        let after = region(rows, cursorY: 3)
        let verdict = MailboxDoorbellSequence.preReturn(
            rowIsCurrent: true,
            operatorInputUnchanged: true,
            agentOwnsTerminal: true,
            captured: true,
            prompt: PromptInputClassifier.classify(after, harness: "claude-code").state,
            composer: PromptInputClassifier.composerText(after, harness: "claude-code")
        )
        XCTAssertNotNil(verdict, "the Return would submit the operator's draft with the doorbell line")
    }

    func testDispatchPiIdleOnAClaudePanelReadsUnknown() {
        let state = PromptInputClassifier.classify(piIdle(), harness: "claude-code").state
        XCTAssertEqual(state, .unknown)
        XCTAssertFalse(FeedAnswerPromptCommit.admits(state))
    }

    func testDispatchOpenCodeIdleOnAPiPanelReadsUnknown() {
        let state = PromptInputClassifier.classify(openCodeIdle(), harness: "pi").state
        XCTAssertEqual(state, .unknown)
        XCTAssertFalse(FeedAnswerPromptCommit.admits(state))
    }

    func testDispatchGrokIdleOnAnOpenCodePanelReadsUnknown() {
        let state = PromptInputClassifier.classify(grokIdle(), harness: "opencode").state
        XCTAssertEqual(state, .unknown)
        XCTAssertFalse(FeedAnswerPromptCommit.admits(state))
    }

    func testDispatchClaudeIdleOnAPiPanelReadsUnknown() {
        let state = PromptInputClassifier.classify(claudeIdle(), harness: "pi").state
        XCTAssertEqual(state, .unknown)
        XCTAssertFalse(FeedAnswerPromptCommit.admits(state))
    }

    func testDispatchGrokIdleOnAClaudePanelReadsUnknown() {
        let state = PromptInputClassifier.classify(grokIdle(), harness: "claude-code").state
        XCTAssertEqual(state, .unknown)
    }

    func testDispatchClaudeIdleOnAGrokPanelReadsUnknown() {
        let state = PromptInputClassifier.classify(claudeIdle(), harness: "grok").state
        XCTAssertEqual(state, .unknown)
    }

    func testUnknownHarnessReadsUnknown() {
        let screens = [claudeIdle(), piIdle(), openCodeIdle(), grokIdle()]
        for harness in [nil, "omp", "github-copilot", "shell", "kimi"] {
            for screen in screens {
                XCTAssertEqual(
                    PromptInputClassifier.classify(screen, harness: harness).state,
                    .unknown,
                    "harness \(harness ?? "nil") admitted a composer"
                )
            }
        }
    }

    /// An untyped panel still refuses a Claude draft. Empty stays unknown.
    func testUnknownHarnessRefusesAClaudeDraft() {
        let draft = region([
            Row(y: 0, spans: [Span(text: liveRule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}notes:")]),
            Row(y: 2, spans: [Span(text: liveRule)]),
        ], cursorY: 1)
        for harness in [nil, "omp", "github-copilot", "shell", "kimi"] {
            let state = PromptInputClassifier.classify(draft, harness: harness).state
            XCTAssertEqual(state, .draft, "harness \(harness ?? "nil") reads \(state)")
            XCTAssertFalse(FeedAnswerPromptCommit.admits(state))
            XCTAssertEqual(
                SendInputGuard.decide(state: state, allowUnguarded: false),
                .refuse(reason: "draft")
            )
        }
    }

    func testUnknownHarnessEmptyClaudePromptStaysUnknown() {
        for harness in [nil, "omp", "github-copilot", "shell", "kimi"] {
            let state = PromptInputClassifier.classify(claudeIdle(), harness: harness).state
            XCTAssertEqual(state, .unknown, "harness \(harness ?? "nil") reads \(state)")
            XCTAssertFalse(FeedAnswerPromptCommit.admits(state))
            XCTAssertEqual(
                SendInputGuard.decide(state: state, allowUnguarded: false),
                .deliver(.unknown)
            )
        }
    }

    private var piLiveRule: String { String(repeating: "─", count: 69) }

    func testR1V3PiLiveDraftEndingInARuleRowIsNotEmpty() {
        let rows = [
            Row(y: 0, spans: [Span(text: piLiveRule)]),
            Row(y: 1, spans: [Span(text: "notes:" + String(repeating: " ", count: 63))]),
            Row(y: 2, spans: [Span(text: "────────────" + String(repeating: " ", count: 57))]),
            Row(y: 3, spans: [Span(text: String(repeating: " ", count: 69))]),
            Row(y: 4, spans: [Span(text: piLiveRule)]),
        ]
        let state = PromptInputClassifier.classify(region(rows, cursorY: 3), harness: "pi").state
        XCTAssertFalse(FeedAnswerPromptCommit.admits(state), "Pi draft ending in a rule row reads \(state)")
    }

    func testR1V3DoorbellAfterPiRuleDraftIsNotSubmitted() {
        let rows = [
            Row(y: 0, spans: [Span(text: piLiveRule)]),
            Row(y: 1, spans: [Span(text: "notes:" + String(repeating: " ", count: 63))]),
            Row(y: 2, spans: [Span(text: "────────────" + String(repeating: " ", count: 57))]),
            Row(y: 3, spans: [Span(text: MailboxDoorbell.text)]),
            Row(y: 4, spans: [Span(text: piLiveRule)]),
        ]
        let after = region(rows, cursorY: 3)
        let verdict = MailboxDoorbellSequence.preReturn(
            rowIsCurrent: true,
            operatorInputUnchanged: true,
            agentOwnsTerminal: true,
            captured: true,
            prompt: PromptInputClassifier.classify(after, harness: "pi").state,
            composer: PromptInputClassifier.composerText(after, harness: "pi")
        )
        XCTAssertNotNil(verdict, "the Return would submit the operator's Pi draft with the doorbell line")
    }

    private var liveRule: String { String(repeating: "─", count: 69) }

    private func claudeIdle() -> PromptRegionSnapshot {
        region([
            Row(y: 0, spans: [Span(text: liveRule)]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0} ")]),
            Row(y: 2, spans: [Span(text: liveRule)]),
        ], cursorY: 1)
    }

    private func piIdle() -> PromptRegionSnapshot {
        region([
            Row(y: 0, spans: [Span(text: liveRule)]),
            Row(y: 1, spans: [Span(text: " ")]),
            Row(y: 2, spans: [Span(text: liveRule)]),
        ], cursorY: 1)
    }

    private func openCodeIdle() -> PromptRegionSnapshot {
        region([
            Row(y: 0, spans: [Span(text: "  ┃")]),
            Row(y: 1, spans: [Span(text: "  ┃  Ask anything… \"Fix a TODO in the codebase\"", faint: true)]),
            Row(y: 2, spans: [Span(text: "  ┃")]),
            Row(y: 3, spans: [Span(text: "  ┃  K3-256k · K3-256k Kimi For Coding · high")]),
            Row(y: 4, spans: [Span(text: "  ╹" + String(repeating: "▀", count: 60))]),
        ], cursorY: 1)
    }

    private func grokIdle() -> PromptRegionSnapshot {
        let top = "╭" + String(repeating: "─", count: 20) + "╮"
        let prompt = "│ ❯" + String(repeating: " ", count: 16) + "│"
        let bottom = "╰──────── Grok 4.7 · always-approve ─╯"
        return region([
            Row(y: 0, spans: [Span(text: top)]),
            Row(y: 1, spans: [Span(text: prompt)]),
            Row(y: 2, spans: [Span(text: bottom)]),
        ], cursorY: 1)
    }
}

// MARK: - C11-406 Grok's italic next-prompt suggestion

/// Real Grok 1.0.50 (Grok 4.7, 100x30) screens, replayed from the raw pty
/// bytes. Grok draws its suggestion `ESC[3m ESC[38;2;88;88;88m`: italic grey,
/// never SGR 2. Each fixture is the native capture window (9 rows above the
/// cursor, 6 below) with each cell's faint and italic bits.
final class GrokPromptSuggestionTests: XCTestCase {
    func testCapturedGrokSuggestionIsASuggestion() {
        for capture in [GrokCaptures.suggestion, GrokCaptures.suggestionAfterClear,
                        GrokCaptures.narrowTruncatedSuggestion] {
            let region = capture.region()
            XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok"),
                           .init(state: .suggestion, draftLength: nil))
            XCTAssertNil(PromptInputClassifier.composerText(region, harness: "grok"))
        }
    }

    func testCapturedGrokSuggestionRingsAndAdmitsSend() {
        let state = PromptInputClassifier.classify(GrokCaptures.suggestion.region(), harness: "grok").state
        XCTAssertEqual(MailboxDoorbell.decide(.init(prompt: state)), .ring)
        XCTAssertEqual(SendInputGuard.decide(state: state, allowUnguarded: false), .deliver(.checked))
    }

    /// Fail closed: a capture with no italic bit is the pre-fix read.
    func testSuggestionWithoutTheItalicSignalIsADraft() {
        let region = GrokCaptures.suggestion.region(dropItalic: true)
        XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok").state, .draft)
        XCTAssertEqual(SendInputGuard.decide(state: .draft, allowUnguarded: false), .refuse(reason: "draft"))
    }

    func testCapturedGrokTypedTextStaysADraft() {
        let cases: [(GrokCapture, String)] = [
            (GrokCaptures.typedOverSuggestion, "x"),
            (GrokCaptures.typedDraft, "Reply with the one word ALPHA and stop."),
            (GrokCaptures.pastePlaceholder, "[Pasted: 6 lines]"),
            (GrokCaptures.slashCompletion, "/model"),
            (GrokCaptures.doorbellPasted, MailboxDoorbell.text),
        ]
        for (capture, text) in cases {
            let region = capture.region()
            XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok").state, .draft, text)
            XCTAssertEqual(PromptInputClassifier.composerText(region, harness: "grok"), text)
        }
    }

    func testDoorbellPastedOverTheSuggestionMatchesBeforeReturn() {
        let region = GrokCaptures.doorbellPasted.region()
        let compared = FeedAnswerComposerCheck.compare(
            state: PromptInputClassifier.classify(region, harness: "grok").state,
            composer: PromptInputClassifier.composerText(region, harness: "grok"),
            expected: MailboxDoorbell.text
        )
        XCTAssertEqual(compared, .matches)
    }

    func testCapturedGrokEmptyComposerIsEmpty() {
        XCTAssertEqual(PromptInputClassifier.classify(GrokCaptures.emptyAfterEscape.region(), harness: "grok").state, .empty)
    }

    /// An italic draft with the cursor at its end (where typing leaves it).
    func testItalicTextWithTheCursorPastItsStartIsADraft() {
        let region = GrokCaptures.suggestion.region(cursorX: 47)
        XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok").state, .draft)
    }

    /// The cursor on the first cell, but one upright character (the `o` of
    /// `one`) in the text.
    func testItalicTextWithAnyUprightCharacterIsADraft() {
        let region = GrokCaptures.suggestion.region(uprightAt: (y: 25, x: 21))
        XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok").state, .draft)
    }

    /// Upright typed text with the cursor moved home, then italic text.
    func testUprightFirstCharacterIsADraft() {
        let region = GrokCaptures.suggestion.region(uprightAt: (y: 25, x: 6))
        XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok").state, .draft)
    }

    /// Two italic rows with the cursor at the second row's first cell: the
    /// cursor is not on the prompt row, so this is not the suggestion shape.
    func testItalicTextWithTheCursorOffThePromptRowIsADraft() {
        var rows = GrokCaptures.suggestion.rows.filter { $0.0 <= 25 }
        rows.append((26, [S("  │ "), S("  and keep going", italic: true), S("   │  ")]))
        rows.append((27, [S("  ╰──── Grok 4.7 (high) · always-approve ─╯  ")]))
        let region = GrokCapture(cursorX: 6, cursorY: 26, rows: rows).region()
        XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok").state, .draft)
    }

    /// Grok predicts the line a seat sees most: the doorbell line itself.
    /// Whole or cut short with Grok's italic ellipsis, it is a suggestion, so
    /// it is neither a draft nor a stranded invitation.
    func testDoorbellLineAsGroksSuggestionIsASuggestion() {
        let whole = GrokCapture.suggestionRow(MailboxDoorbell.text)
        let cut = GrokCapture.suggestionRow(String(MailboxDoorbell.text.prefix(33)) + "…")
        for capture in [whole, cut] {
            let region = capture.region()
            XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok").state, .suggestion)
            XCTAssertNil(PromptInputClassifier.composerText(region, harness: "grok"))
            XCTAssertEqual(MailboxDoorbell.decide(.init(prompt: .suggestion)), .ring)
            XCTAssertEqual(PromptInputClassifier.classify(capture.region(dropItalic: true), harness: "grok").state, .draft)
        }
    }

    /// An upright space on the cursor cell, then italic text: the cursor is
    /// not on the suggestion's first glyph.
    func testUprightSpaceAtTheCursorBeforeItalicTextIsADraft() {
        let capture = GrokCapture(cursorX: 6, cursorY: 25, rows: [
            (24, [S("  ╭" + String(repeating: "─", count: 50) + "╮  ")]),
            (25, [S("  │ ❯  "), S("Reply with the one word CHARLIE and stop.", italic: true), S("    │  ")]),
            (26, [S("  ╰──── Grok 4.7 (high) · always-approve ─╯  ")]),
        ])
        XCTAssertEqual(PromptInputClassifier.classify(capture.region(), harness: "grok").state, .draft)
    }

    /// Italic is Grok's signal only. Other readers see the Grok capture as
    /// they did before: never a suggestion.
    func testGrokSuggestionCaptureOnOtherPanelsIsNotASuggestion() {
        for harness in ["claude-code", "codex", "opencode", "pi", "omp", nil] as [String?] {
            XCTAssertNotEqual(PromptInputClassifier.classify(GrokCaptures.suggestion.region(), harness: harness).state,
                              .suggestion, harness ?? "untyped")
        }
    }

    /// Italic is Grok's signal only. Claude's reader still needs faint.
    func testItalicOnAClaudeComposerIsADraft() {
        var cells: [PromptRegionCell] = []
        var bytes = Data()
        var rows: [PromptRegionRow] = []
        let lines = [String(repeating: "─", count: 40), "❯\u{00A0}", String(repeating: "─", count: 40)]
        for (y, text) in lines.enumerated() {
            let start = cells.count
            var scalars = Array(text.unicodeScalars).map { ($0, false) }
            if y == 1 { scalars += "fix the lint errors".unicodeScalars.map { ($0, true) } }
            for (scalar, italic) in scalars {
                let encoded = Array(String(scalar).utf8)
                cells.append(PromptRegionCell(textOffset: bytes.count, textLength: encoded.count, faint: false, italic: italic))
                bytes.append(contentsOf: encoded)
            }
            rows.append(PromptRegionRow(screenY: y, cellRange: start..<cells.count, softWrap: false, wrapContinuation: false))
        }
        let region = PromptRegionSnapshot(cursorX: 2, cursorY: 1, cursorPendingWrap: false, complete: true,
                                          rows: rows, cells: cells, text: bytes)
        XCTAssertEqual(PromptInputClassifier.classify(region, harness: "claude-code").state, .draft)
    }
}

/// C11-414. Grok's composer after a click in its transcript. Grok draws it
/// dim, hides the cursor and parks it on the footer, or far above after a
/// hover. Real Grok 1.0.52 takes a paste there into the composer and
/// refocuses it, so the dim placeholder rings; a typed draft that lost focus
/// would take the paste spliced onto it, so it never rings.
final class GrokUnfocusedComposerTests: XCTestCase {
    private let placeholders = [
        GrokUnfocusedCaptures.unfocusedPlaceholderBelow,
        GrokUnfocusedCaptures.unfocusedPlaceholderAbove,
    ]

    func testUnfocusedPlaceholderIsASuggestionThatRings() {
        for capture in placeholders {
            let region = capture.region()
            XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok"),
                           .init(state: .suggestion, draftLength: nil))
            XCTAssertNil(PromptInputClassifier.composerText(region, harness: "grok"))
            let state = PromptInputClassifier.classify(region, harness: "grok").state
            XCTAssertEqual(MailboxDoorbell.decide(.init(prompt: state)), .ring)
            XCTAssertEqual(SendInputGuard.decide(state: state, allowUnguarded: false), .deliver(.checked))
        }
    }

    /// Typed text that lost focus has the placeholder's bits and differs only
    /// in its brighter grey. The literal `Build anything`, typed, is a draft
    /// focused or not.
    func testTypedTextIsADraftFocusedOrNot() {
        let cases: [(GrokCapture, String)] = [
            (GrokUnfocusedCaptures.unfocusedTypedDraftBelow, "fix the lint errors"),
            (GrokUnfocusedCaptures.unfocusedTypedDraftAbove, "fix the lint errors"),
            (GrokUnfocusedCaptures.unfocusedTypedBuildAnythingBelow, "Build anything"),
            (GrokUnfocusedCaptures.unfocusedTypedBuildAnythingAbove, "Build anything"),
            (GrokUnfocusedCaptures.typedBuildAnythingFocused, "Build anything"),
        ]
        for (capture, text) in cases {
            let region = capture.region()
            XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok"),
                           .init(state: .draft, draftLength: text.count), text)
            XCTAssertEqual(PromptInputClassifier.composerText(region, harness: "grok"), text)
            XCTAssertEqual(MailboxDoorbell.decide(.init(prompt: .draft)), .skip(reason: "draft"))
            XCTAssertEqual(SendInputGuard.decide(state: .draft, allowUnguarded: false), .refuse(reason: "draft"))
        }
    }

    /// The doorbell line left unsubmitted, then a transcript click: still
    /// the stranded invitation, which is never typed over.
    func testUnfocusedStrandedDoorbellLineIsTheInvitation() {
        let region = GrokUnfocusedCaptures.unfocusedDoorbellStrandedBelow.region()
        let state = PromptInputClassifier.classify(region, harness: "grok").state
        XCTAssertEqual(state, .draft)
        XCTAssertEqual(FeedAnswerComposerCheck.compare(
            state: state,
            composer: PromptInputClassifier.composerText(region, harness: "grok"),
            expected: MailboxDoorbell.text
        ), .matches)
    }

    /// Fail closed: without colors the placeholder is typed text.
    func testUnfocusedPlaceholderWithoutColorIsADraft() {
        for capture in placeholders {
            XCTAssertEqual(PromptInputClassifier.classify(capture.region(dropColor: true), harness: "grok").state, .draft)
        }
    }

    /// One character in the typed grey makes the composer a draft.
    func testOneBrightCharacterInTheUnfocusedComposerIsADraft() {
        for capture in placeholders {
            let region = capture.region(recolor: { y, x, fg in y == 25 && x == 10 ? 0x9B9B9B : fg })
            XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok").state, .draft)
        }
    }

    /// A hover parks the cursor 17 rows above the composer. Only the screen's
    /// bottom rows hold it; without them, or with a clipped read, it stays
    /// unknown and is not rung.
    func testComposerOutsideTheCursorWindowNeedsTheBottomRows() {
        for capture in [GrokUnfocusedCaptures.unfocusedPlaceholderAbove,
                        GrokUnfocusedCaptures.unfocusedTypedDraftAbove] {
            XCTAssertEqual(PromptInputClassifier.classify(capture.region(dropBottom: true), harness: "grok").state, .unknown)
            XCTAssertEqual(PromptInputClassifier.classify(capture.region(bottomIncomplete: true), harness: "grok").state, .unknown)
        }
    }

    /// With the cursor inside the box the composer is focused, and the
    /// focused reader decides: upright `Build anything` there is a draft.
    func testCursorInsideTheBoxUsesTheFocusedReader() {
        let region = GrokUnfocusedCaptures.unfocusedPlaceholderBelow.region(cursorX: 6, cursorY: 25)
        XCTAssertEqual(PromptInputClassifier.classify(region, harness: "grok").state, .draft)
    }

    /// Grok's transcript hover box has square corners around a `│   ❯` past
    /// prompt. It is not the composer, even when its text is dim.
    func testSquareCorneredBoxIsNotTheComposer() {
        let dim: UInt32 = 0x4E4E4E
        let bg: UInt32 = 0x141414
        let capture = GrokCapture(cursorX: 10, cursorY: 24, rows: [
            (20, [S("  ┌" + String(repeating: "─", count: 40) + "┐", fg: dim, bg: bg)]),
            (21, [S("  │ ❯ ", fg: dim, bg: bg), S("Build anything", fg: dim, bg: bg), S("                          │", fg: dim, bg: bg)]),
            (22, [S("  └" + String(repeating: "─", count: 40) + "┘", fg: dim, bg: bg)]),
            (23, [S("")]),
            (24, [S("  Ctrl+e:expand thinking  │  Space:prompt", fg: 0x6C6C6C, bg: bg)]),
        ])
        XCTAssertEqual(PromptInputClassifier.classify(capture.region(), harness: "grok").state, .unknown)
    }

    func testOnlyGrokReadsTheScreenBottom() {
        XCTAssertTrue(PromptInputClassifier.readsScreenBottom(harness: "grok"))
        XCTAssertTrue(PromptInputClassifier.readsScreenBottom(harness: " Grok "))
        for harness in ["claude-code", "codex", "opencode", "pi", "omp", "copilot", nil] as [String?] {
            XCTAssertFalse(PromptInputClassifier.readsScreenBottom(harness: harness), harness ?? "untyped")
        }
    }

    /// The unfocused reading is Grok's only. Other readers never call these
    /// captures empty or a suggestion, so they are not rung.
    func testUnfocusedCapturesOnOtherPanelsAreNotRung() {
        for capture in placeholders {
            for harness in ["claude-code", "codex", "opencode", "pi", "omp", nil] as [String?] {
                let state = PromptInputClassifier.classify(capture.region(), harness: harness).state
                XCTAssertFalse(state == .empty || state == .suggestion, harness ?? "untyped")
            }
        }
    }

    /// Grok 1.0.52's greys on its own background, either side of 3:1.
    func testContrastRuleSeparatesGroksGreys() {
        let bg: UInt32 = 0x141414
        XCTAssertLessThan(PromptInputClassifier.contrastRatio(0x4E4E4E, bg), PromptInputClassifier.ghostTextContrast)
        XCTAssertLessThan(PromptInputClassifier.contrastRatio(0x585858, bg), PromptInputClassifier.ghostTextContrast)
        XCTAssertGreaterThan(PromptInputClassifier.contrastRatio(0x9B9B9B, bg), PromptInputClassifier.ghostTextContrast)
        XCTAssertGreaterThan(PromptInputClassifier.contrastRatio(0xE1E1E1, bg), PromptInputClassifier.ghostTextContrast)
        XCTAssertEqual(PromptInputClassifier.contrastRatio(0xFFFFFF, 0x000000), 21, accuracy: 0.01)
        XCTAssertEqual(PromptInputClassifier.contrastRatio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }
}

/// C11-406 review H: three sub-guards of Grok's italic-suggestion rule, each
/// pinned by a shape no Grok draws. Every one fails closed to a draft.
final class GrokSuggestionSubGuardTests: XCTestCase {
    private func box(_ rows: [(Int, [S])]) -> GrokCapture {
        GrokCapture(cursorX: 6, cursorY: 25, rows:
            [(24, [S("  ╭" + String(repeating: "─", count: 50) + "╮  ")])] + rows)
    }

    /// The first content cell is an italic space, not an italic glyph.
    func testItalicSpaceOnTheCursorCellIsADraft() {
        let capture = box([
            (25, [S("  │ ❯ "), S(" Reply with the one word CHARLIE and stop.", italic: true), S("   │  ")]),
            (26, [S("  ╰──── Grok 4.7 (high) · always-approve ─╯  ")]),
        ])
        XCTAssertEqual(PromptInputClassifier.classify(capture.region(), harness: "grok").state, .draft)
    }

    /// Only the prompt row's first cell counts. A continuation row that
    /// starts with an italic glyph does not stand in for it.
    func testOnlyThePromptRowsFirstCellCounts() {
        let capture = box([
            (25, [S("  │ ❯ "), S(" Reply with the one word", italic: true), S("     │  ")]),
            (26, [S("  │ "), S("CHARLIE and stop.", italic: true), S("     │  ")]),
            (27, [S("  ╰──── Grok 4.7 (high) · always-approve ─╯  ")]),
        ])
        XCTAssertEqual(PromptInputClassifier.classify(capture.region(), harness: "grok").state, .draft)
    }

    /// A faint first cell is not the suggestion's italic glyph.
    func testFaintItalicFirstCellIsADraft() {
        let capture = box([
            (25, [S("  │ ❯ "), S("R", faint: true, italic: true),
                  S("eply with the one word CHARLIE and stop.", italic: true), S("   │  ")]),
            (26, [S("  ╰──── Grok 4.7 (high) · always-approve ─╯  ")]),
        ])
        XCTAssertEqual(PromptInputClassifier.classify(capture.region(), harness: "grok").state, .draft)
    }
}

/// The native import carries every cell field. C11-406 review: the italic
/// wiring had no test; C11-414 adds the truecolor fields beside it.
final class PromptRegionNativeImportTests: XCTestCase {
    func testImportCarriesItalicAndTruecolor() throws {
        var native = ghostty_prompt_region_s()
        native.cursor_x = 1
        native.cursor_y = 7
        native.row_count = 1
        native.cell_count = 3
        native.text_len = 3
        native.complete = true
        var row = ghostty_prompt_region_row_s()
        row.screen_y = 7
        row.cell_start = 0
        row.cell_count = 3
        var plain = ghostty_prompt_region_cell_s()
        plain.text_offset = 0
        plain.text_len = 1
        var styled = ghostty_prompt_region_cell_s()
        styled.text_offset = 1
        styled.text_len = 1
        styled.italic = true
        styled.fg_rgb_set = true
        styled.fg_rgb = 0x4E4E4E
        styled.bg_rgb_set = true
        styled.bg_rgb = 0x141414
        var fgOnly = ghostty_prompt_region_cell_s()
        fgOnly.text_offset = 2
        fgOnly.text_len = 1
        fgOnly.faint = true
        fgOnly.fg_rgb_set = true
        fgOnly.fg_rgb = 0x010203
        fgOnly.bg_rgb = 0x999999
        let text = "abc".utf8.map { CChar(bitPattern: $0) }

        let snapshot = try XCTUnwrap(PromptRegionNativeImport.snapshot(
            native: native, rows: [row], cells: [plain, styled, fgOnly], text: text
        ))
        XCTAssertEqual(snapshot.cursorX, 1)
        XCTAssertEqual(snapshot.cursorY, 7)
        XCTAssertTrue(snapshot.complete)
        XCTAssertEqual(snapshot.rows.first?.cellRange, 0..<3)
        XCTAssertEqual(snapshot.cells[0], PromptRegionCell(textOffset: 0, textLength: 1, faint: false))
        XCTAssertEqual(snapshot.cells[1], PromptRegionCell(textOffset: 1, textLength: 1, faint: false, italic: true,
                                                           fg: 0x4E4E4E, bg: 0x141414))
        XCTAssertEqual(snapshot.cells[2], PromptRegionCell(textOffset: 2, textLength: 1, faint: true,
                                                           fg: 0x010203, bg: nil))
        XCTAssertEqual(snapshot.text, Data("abc".utf8))
        XCTAssertNil(snapshot.screenBottom)
    }

    func testImportDropsCountsPastTheBuffers() {
        var native = ghostty_prompt_region_s()
        native.row_count = 1
        native.cell_count = 2
        var row = ghostty_prompt_region_row_s()
        row.cell_count = 2
        XCTAssertNil(PromptRegionNativeImport.snapshot(
            native: native, rows: [row], cells: [ghostty_prompt_region_cell_s()], text: []
        ))
        native.cell_count = 1
        XCTAssertNil(PromptRegionNativeImport.snapshot(
            native: native, rows: [row], cells: [ghostty_prompt_region_cell_s()], text: []
        ))
    }
}

private struct GrokCapture {
    let cursorX: Int
    let cursorY: Int
    let rows: [(Int, [S])]
    /// The screen's last 16 rows, as Grok panels also read them.
    var bottomRows: [(Int, [S])]? = nil

    struct S {
        let text: String
        var faint = false
        var italic = false
        var fg: UInt32?
        var bg: UInt32?
        init(_ text: String, faint: Bool = false, italic: Bool = false, fg: UInt32? = nil, bg: UInt32? = nil) {
            self.text = text
            self.faint = faint
            self.italic = italic
            self.fg = fg
            self.bg = bg
        }
    }

    /// Grok's composer holding only `text` as its italic suggestion.
    static func suggestionRow(_ text: String) -> GrokCapture {
        GrokCapture(cursorX: 6, cursorY: 25, rows: [
            (24, [S("  ╭" + String(repeating: "─", count: 94) + "╮  ")]),
            (25, [S("  │ ❯ "), S(text, italic: true),
                  S(String(repeating: " ", count: max(1, 92 - text.count)) + "│  ")]),
            (26, [S("  ╰" + String(repeating: "─", count: 59) + " Grok 4.7 (high) · always-approve ─╯  ")]),
            (27, [S("")]),
            (28, [S("  Tab/→:accept suggestion"), S("  │  ", faint: true), S("Shift+Tab:mode")]),
        ])
    }

    /// One cell per scalar. Grok's composer, box and footer are narrow, so
    /// a scalar index is the cell column.
    func region(
        cursorX: Int? = nil,
        cursorY: Int? = nil,
        dropItalic: Bool = false,
        uprightAt: (y: Int, x: Int)? = nil,
        dropColor: Bool = false,
        dropBottom: Bool = false,
        bottomIncomplete: Bool = false,
        recolor: ((Int, Int, UInt32?) -> UInt32?)? = nil
    ) -> PromptRegionSnapshot {
        let window = Self.cells(rows, dropItalic: dropItalic, uprightAt: uprightAt, dropColor: dropColor, recolor: recolor)
        var snapshot = PromptRegionSnapshot(
            cursorX: cursorX ?? self.cursorX,
            cursorY: cursorY ?? self.cursorY,
            cursorPendingWrap: false,
            complete: true,
            rows: window.rows,
            cells: window.cells,
            text: window.text
        )
        if let bottomRows, !dropBottom {
            let bottom = Self.cells(bottomRows, dropItalic: dropItalic, uprightAt: uprightAt, dropColor: dropColor, recolor: recolor)
            snapshot.screenBottom = PromptRegionRows(
                complete: !bottomIncomplete,
                rows: bottom.rows,
                cells: bottom.cells,
                text: bottom.text
            )
        }
        return snapshot
    }

    /// `recolor` maps (row, column, fg) to the fg a cell gets instead.
    private static func cells(
        _ rows: [(Int, [S])],
        dropItalic: Bool,
        uprightAt: (y: Int, x: Int)?,
        dropColor: Bool,
        recolor: ((Int, Int, UInt32?) -> UInt32?)?
    ) -> (rows: [PromptRegionRow], cells: [PromptRegionCell], text: Data) {
        var bytes = Data()
        var cells: [PromptRegionCell] = []
        var outputRows: [PromptRegionRow] = []
        for (y, spans) in rows {
            let start = cells.count
            var x = 0
            for span in spans {
                for scalar in span.text.unicodeScalars {
                    let encoded = Array(String(scalar).utf8)
                    var italic = span.italic && !dropItalic
                    if let upright = uprightAt, upright.y == y, upright.x == x { italic = false }
                    var fg = dropColor ? nil : span.fg
                    if let recolor { fg = recolor(y, x, fg) }
                    cells.append(PromptRegionCell(
                        textOffset: bytes.count, textLength: encoded.count,
                        faint: span.faint, italic: italic,
                        fg: fg, bg: dropColor ? nil : span.bg
                    ))
                    bytes.append(contentsOf: encoded)
                    x += 1
                }
            }
            outputRows.append(PromptRegionRow(
                screenY: y, cellRange: start..<cells.count, softWrap: false, wrapContinuation: false
            ))
        }
        return (outputRows, cells, bytes)
    }
}

private typealias S = GrokCapture.S

// Generated from real Grok 1.0.50 (Grok 4.7) pty captures by gen_fixture.py.
private enum GrokCaptures {
    /// Grok 4.7 after two same-shaped turns: italic grey suggestion, cursor on its first cell.
    static let suggestion = GrokCapture(cursorX: 6, cursorY: 25, rows: [
        (16, [S("                                                                                                   █")]),
        (17, [S("                                                                                                   █")]),
        (18, [S("                                                                                                   █")]),
        (19, [S("                                                                                                   █")]),
        (20, [S("                                                                                                   █")]),
        (21, [S("                                                                                                   █")]),
        (22, [S("                                                                                                   █")]),
        (23, [S("                                                                                                    ")]),
        (24, [S("  ╭──────────────────────────────────────────────────────────────────────────────────────────────╮  ")]),
        (25, [S("  │ ❯ "), S("Reply with the one word CHARLIE and stop.", italic: true), S("                                                  │  ")]),
        (26, [S("  ╰─────────────────────────────────────────────────────────── Grok 4.7 (high) · always-approve ─╯  ")]),
        (27, [S("                                                                                                    ")]),
        (28, [S("  Tab/→:accept suggestion"), S("  │  ", faint: true), S("Shift+Tab:mode"), S("  │  ", faint: true), S("Ctrl+.:shortcuts                                   ")]),
        (29, [S("                                                                                                    ")]),
    ])

    /// Ctrl+U over a pasted line: the suggestion is redrawn.
    static let suggestionAfterClear = GrokCapture(cursorX: 6, cursorY: 25, rows: [
        (16, [S("                                                                                                   █")]),
        (17, [S("                                                                                                   █")]),
        (18, [S("                                                                                                   █")]),
        (19, [S("                                                                                                   █")]),
        (20, [S("                                                                                                   █")]),
        (21, [S("                                                                                                    ")]),
        (22, [S("   Input cleared · ctrl+z to undo                                                                   ")]),
        (23, [S("                                                                                                    ")]),
        (24, [S("  ╭──────────────────────────────────────────────────────────────────────────────────────────────╮  ")]),
        (25, [S("  │ ❯ "), S("Reply with the one word CHARLIE and stop.", italic: true), S("                                                  │  ")]),
        (26, [S("  ╰─────────────────────────────────────────────────────────── Grok 4.7 (high) · always-approve ─╯  ")]),
        (27, [S("                                                                                                    ")]),
        (28, [S("  Tab/→:accept suggestion"), S("  │  ", faint: true), S("Shift+Tab:mode"), S("  │  ", faint: true), S("Ctrl+.:shortcuts                                   ")]),
        (29, [S("                                                                                                    ")]),
    ])

    /// One key typed over the suggestion: the suggestion is gone, `x` is upright.
    static let typedOverSuggestion = GrokCapture(cursorX: 7, cursorY: 25, rows: [
        (16, [S("                                                                                                   █")]),
        (17, [S("                                                                                                   █")]),
        (18, [S("                                                                                                   █")]),
        (19, [S("                                                                                                   █")]),
        (20, [S("                                                                                                   █")]),
        (21, [S("                                                                                                   █")]),
        (22, [S("                                                                                                   █")]),
        (23, [S("                                                                                                    ")]),
        (24, [S("  ╭──────────────────────────────────────────────────────────────────────────────────────────────╮  ")]),
        (25, [S("  │ ❯ x                                                                                          │  ")]),
        (26, [S("  ╰─────────────────────────────────────────────────────────── Grok 4.7 (high) · always-approve ─╯  ")]),
        (27, [S("                                                                                                    ")]),
        (28, [S("  Enter:send"), S("  │  ", faint: true), S("Shift+Enter/Opt+Enter:newline"), S("  │  ", faint: true), S("Shift+Tab:mode"), S("  │  ", faint: true), S("Ctrl+.:shortcuts              ")]),
        (29, [S("                                                                                                    ")]),
    ])

    /// A typed prompt before Enter.
    static let typedDraft = GrokCapture(cursorX: 45, cursorY: 25, rows: [
        (16, [S("                                                                                                    ")]),
        (17, [S("                                                                                                    ")]),
        (18, [S("                                                                                                    ")]),
        (19, [S("                                                                                                    ")]),
        (20, [S("                                                                                                    ")]),
        (21, [S("                                                                                                    ")]),
        (22, [S("                                                                                                    ")]),
        (23, [S("                                                                                                    ")]),
        (24, [S("  ╭──────────────────────────────────────────────────────────────────────────────────────────────╮  ")]),
        (25, [S("  │ ❯ Reply with the one word ALPHA and stop.                                                    │  ")]),
        (26, [S("  ╰─────────────────────────────────────────────────────────── Grok 4.7 (high) · always-approve ─╯  ")]),
        (27, [S("                                                                                                    ")]),
        (28, [S("  Enter:send"), S("  │  ", faint: true), S("Shift+Enter/Opt+Enter:newline"), S("  │  ", faint: true), S("Shift+Tab:mode"), S("  │  ", faint: true), S("Ctrl+.:shortcuts              ")]),
        (29, [S("                                                                                                    ")]),
    ])

    /// The doorbell line pasted over the suggestion replaces it.
    static let doorbellPasted = GrokCapture(cursorX: 50, cursorY: 25, rows: [
        (16, [S("                                                                                                   █")]),
        (17, [S("                                                                                                   █")]),
        (18, [S("                                                                                                   █")]),
        (19, [S("                                                                                                   █")]),
        (20, [S("                                                                                                   █")]),
        (21, [S("                                                                                                   █")]),
        (22, [S("                                                                                                   █")]),
        (23, [S("                                                                                                    ")]),
        (24, [S("  ╭──────────────────────────────────────────────────────────────────────────────────────────────╮  ")]),
        (25, [S("  │ ❯ c11 mail waiting: run c11 mailbox recv --ack                                               │  ")]),
        (26, [S("  ╰─────────────────────────────────────────────────────────── Grok 4.7 (high) · always-approve ─╯  ")]),
        (27, [S("                                                                                                    ")]),
        (28, [S("  Enter:send"), S("  │  ", faint: true), S("Shift+Enter/Opt+Enter:newline"), S("  │  ", faint: true), S("Shift+Tab:mode"), S("  │  ", faint: true), S("Ctrl+.:shortcuts              ")]),
        (29, [S("                                                                                                    ")]),
    ])

    /// A six-line paste collapsed to `[Pasted: 6 lines]`.
    static let pastePlaceholder = GrokCapture(cursorX: 23, cursorY: 25, rows: [
        (16, [S("              │line one of a paste                                                   │             █")]),
        (17, [S("              │line two                                                              │             █")]),
        (18, [S("              │line three                                                            │             █")]),
        (19, [S("              │line four                                                             │             █")]),
        (20, [S("              │line five                                                             │             █")]),
        (21, [S("              │line six                                                              │             █")]),
        (22, [S("              ╰─ paste again or double-click to expand ──────────────────────────────╯             █")]),
        (23, [S("                                                                                                    ")]),
        (24, [S("  ╭──────────────────────────────────────────────────────────────────────────────────────────────╮  ")]),
        (25, [S("  │ ❯ [Pasted: 6 lines]                                                                          │  ")]),
        (26, [S("  ╰─────────────────────────────────────────────────────────── Grok 4.7 (high) · always-approve ─╯  ")]),
        (27, [S("                                                                                                    ")]),
        (28, [S("  Enter:send"), S("  │  ", faint: true), S("Shift+Enter/Opt+Enter:newline"), S("  │  ", faint: true), S("Shift+Tab:mode"), S("  │  ", faint: true), S("Ctrl+.:shortcuts              ")]),
        (29, [S("                                                                                                    ")]),
    ])

    /// `/mod` typed; Grok completes `el` in grey, upright.
    static let slashCompletion = GrokCapture(cursorX: 10, cursorY: 25, rows: [
        (16, [S("                                                                                                   █")]),
        (17, [S("  ──────────────────────────────────────────────────────────────────────────────────────────────5─ █")]),
        (18, [S("    ❯ /model         Switch the active model                                                       █")]),
        (19, [S("      /compact-mode  Toggle compact UI (less padding, more content)                                █")]),
        (20, [S("      /vim-mode      Toggle vim-style scrollback keybindings (j/k, h/l, g/G, y/Y, …)               █")]),
        (21, [S("      /resume-codex  Continue from a recent Codex session                                          █")]),
        (22, [S("      /import-claude Open the Claude settings import modal                                         █")]),
        (23, [S("  ────────────────────────────────────────────────────────────────────────────────────────────────  ")]),
        (24, [S("  ╭──────────────────────────────────────────────────────────────────────────────────────────────╮  ")]),
        (25, [S("  │ ❯ /model                                                                                     │  ")]),
        (26, [S("  ╰─────────────────────────────────────────────────────────── Grok 4.7 (high) · always-approve ─╯  ")]),
        (27, [S("                                                                                                    ")]),
        (28, [S("  Enter:send"), S("  │  ", faint: true), S("Shift+Enter/Opt+Enter:newline"), S("  │  ", faint: true), S("Shift+Tab:mode"), S("  │  ", faint: true), S("Ctrl+.:shortcuts              ")]),
        (29, [S("                                                                                                    ")]),
    ])

    /// Escape dismissed the suggestion: an empty composer.
    static let emptyAfterEscape = GrokCapture(cursorX: 6, cursorY: 25, rows: [
        (16, [S("                                                                                                   █")]),
        (17, [S("                                                                                                   █")]),
        (18, [S("                                                                                                   █")]),
        (19, [S("                                                                                                   █")]),
        (20, [S("                                                                                                   █")]),
        (21, [S("                                                                                                   █")]),
        (22, [S("                                                                                                   █")]),
        (23, [S("                                                                                                    ")]),
        (24, [S("  ╭──────────────────────────────────────────────────────────────────────────────────────────────╮  ")]),
        (25, [S("  │ ❯                                                                                            │  ")]),
        (26, [S("  ╰─────────────────────────────────────────────────────────── Grok 4.7 (high) · always-approve ─╯  ")]),
        (27, [S("                                                                                                    ")]),
        (28, [S("  Shift+Tab:mode"), S("  │  ", faint: true), S("Ctrl+.:shortcuts                                                               ")]),
        (29, [S("                                                                                                    ")]),
    ])

    /// A 44-column pane: Grok truncates the suggestion on one row with an italic ellipsis.
    static let narrowTruncatedSuggestion = GrokCapture(cursorX: 6, cursorY: 25, rows: [
        (16, [S("                                           █")]),
        (17, [S("                                           █")]),
        (18, [S("                                           █")]),
        (19, [S("                                           █")]),
        (20, [S("                                           █")]),
        (21, [S("                                           █")]),
        (22, [S("                                           █")]),
        (23, [S("                                            ")]),
        (24, [S("  ╭──────────────────────────────────────╮  ")]),
        (25, [S("  │ ❯ "), S("Reply with the one word CHARLIE a…", italic: true), S(" │  ")]),
        (26, [S("  ╰─── Grok 4.7 (high) · always-approve ─╯  ")]),
        (27, [S("                                            ")]),
        (28, [S("  Tab/→:accept suggestion"), S("  │  ", faint: true), S("Shift+Tab:    ")]),
        (29, [S("                                            ")]),
    ])

}

// Generated from real Grok 1.0.52 (Grok 4.7) pty captures by gen_fixture_414.py.
private enum GrokUnfocusedCaptures {
    /// The operator typed `Build anything` into the focused composer: upright, 225 grey.
    static let typedBuildAnythingFocused = GrokCapture(cursorX: 20, cursorY: 25, rows: [
        (16, [S("                                                                                                    ", bg: 0x141414)]),
        (17, [S("                                                                                                    ", bg: 0x141414)]),
        (18, [S("  ", bg: 0x141414), S("Help improve Grok", fg: 0xE1E1E1, bg: 0x141414), S("                                                             ", bg: 0x141414), S("[Opt out]", fg: 0x787878, bg: 0x141414), S(" ", bg: 0x141414), S("[Opt in]", fg: 0xE1E1E1, bg: 0x141414), S("  ", bg: 0x141414)]),
        (19, [S("  ", bg: 0x141414), S("Off by default. Opt-in to allow SpaceXAI to retain coding data, e.g.,", fg: 0x787878, bg: 0x141414), S("                             ", bg: 0x141414)]),
        (20, [S("  ", bg: 0x141414), S("prompts, traces, & metrics, for training and debugging purposes. Change", fg: 0x787878, bg: 0x141414), S("                           ", bg: 0x141414)]),
        (21, [S("  ", bg: 0x141414), S("anytime via settings.", fg: 0x787878, bg: 0x141414), S("                                                                             ", bg: 0x141414)]),
        (22, [S("  ", bg: 0x141414), S("Read Terms and Privacy Policy.", fg: 0x6C6C6C, bg: 0x141414), S("                                                                    ", bg: 0x141414)]),
        (23, [S("                                                                                                    ", bg: 0x141414)]),
        (24, [S("  ", bg: 0x141414), S("╭──────────────────────────────────────────────────────────────────────────────────────────────╮", fg: 0x505058, bg: 0x141414), S("  ", bg: 0x141414)]),
        (25, [S("  ", bg: 0x141414), S("│", fg: 0x505058, bg: 0x141414), S(" ", fg: 0xE1E1E1, bg: 0x141414), S("❯ ", fg: 0xC8C8C8, bg: 0x141414), S("Build anything                                                                             ", fg: 0xE1E1E1, bg: 0x141414), S("│", fg: 0x505058, bg: 0x141414), S("  ", bg: 0x141414)]),
        (26, [S("  ", bg: 0x141414), S("╰──────────────────────────────────────────────────────────────────────────── ", fg: 0x505058, bg: 0x141414), S("Grok 4.7 (high)", fg: 0x808080, bg: 0x141414), S(" ─╯", fg: 0x505058, bg: 0x141414), S("  ", bg: 0x141414)]),
        (27, [S("                                                                                                    ", bg: 0x141414)]),
        (28, [S("  ", bg: 0x141414), S("Enter", fg: 0xC8C8C8, bg: 0x141414), S(":send", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Opt+Enter", fg: 0xC8C8C8, bg: 0x141414), S(":newline", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Shift+Tab", fg: 0xC8C8C8, bg: 0x141414), S(":mode", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Ctrl+.", fg: 0xC8C8C8, bg: 0x141414), S(":shortcuts                        ", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414)]),
        (29, [S("                                                                                                    ", bg: 0x141414)]),
    ])

    /// A transcript click: dim `Build anything` placeholder (78 grey), cursor hidden on the footer below the box.
    static let unfocusedPlaceholderBelow = GrokCapture(cursorX: 62, cursorY: 28, rows: [
        (19, [S("  ", bg: 0x141414), S("Off by default. Opt-in to allow SpaceXAI to retain coding data, e.g.,", fg: 0x787878, bg: 0x141414), S("                             ", bg: 0x141414)]),
        (20, [S("  ", bg: 0x141414), S("prompts, traces, & metrics, for training and debugging purposes. Change", fg: 0x787878, bg: 0x141414), S("                           ", bg: 0x141414)]),
        (21, [S("  ", bg: 0x141414), S("anytime via settings.", fg: 0x787878, bg: 0x141414), S("                                                                             ", bg: 0x141414)]),
        (22, [S("  ", bg: 0x141414), S("Read Terms and Privacy Policy.", fg: 0x6C6C6C, bg: 0x141414), S("                                                                    ", bg: 0x141414)]),
        (23, [S("                                                                                                    ", bg: 0x141414)]),
        (24, [S("  ", bg: 0x141414), S("╭──────────────────────────────────────────────────────────────────────────────────────────────╮", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (25, [S("  ", bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S(" ", fg: 0x9B9B9B, bg: 0x141414), S("❯ ", fg: 0x414141, bg: 0x141414), S("Build anything", fg: 0x4E4E4E, bg: 0x141414), S("                                                                             ", fg: 0x9B9B9B, bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (26, [S("  ", bg: 0x141414), S("╰──────────────────────────────────────────────────────────────────────────── ", fg: 0x323237, bg: 0x141414), S("Grok 4.7 (high)", fg: 0x5C5C5C, bg: 0x141414), S(" ─╯", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (27, [S("                                                                                                    ", bg: 0x141414)]),
        (28, [S("  ", bg: 0x141414), S("Ctrl+e", fg: 0xC8C8C8, bg: 0x141414), S(":expand thinking", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Space", fg: 0xC8C8C8, bg: 0x141414), S(":prompt", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Ctrl+.", fg: 0xC8C8C8, bg: 0x141414), S(":shortcuts                                    ", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414)]),
        (29, [S("                                                                                                    ", bg: 0x141414)]),
    ])

    /// Typed `Build anything`, then a transcript click: the same text and bits as the placeholder, in 155 grey.
    static let unfocusedTypedBuildAnythingBelow = GrokCapture(cursorX: 74, cursorY: 28, rows: [
        (19, [S("  ", bg: 0x141414), S("Off by default. Opt-in to allow SpaceXAI to retain coding data, e.g.,", fg: 0x787878, bg: 0x141414), S("                             ", bg: 0x141414)]),
        (20, [S("  ", bg: 0x141414), S("prompts, traces, & metrics, for training and debugging purposes. Change", fg: 0x787878, bg: 0x141414), S("                           ", bg: 0x141414)]),
        (21, [S("  ", bg: 0x141414), S("anytime via settings.", fg: 0x787878, bg: 0x141414), S("                                                                             ", bg: 0x141414)]),
        (22, [S("  ", bg: 0x141414), S("Read Terms and Privacy Policy.", fg: 0x6C6C6C, bg: 0x141414), S("                                                                    ", bg: 0x141414)]),
        (23, [S("                                                                                                    ", bg: 0x141414)]),
        (24, [S("  ", bg: 0x141414), S("╭──────────────────────────────────────────────────────────────────────────────────────────────╮", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (25, [S("  ", bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S(" ", fg: 0x9B9B9B, bg: 0x141414), S("❯ ", fg: 0x414141, bg: 0x141414), S("Build anything                                                                             ", fg: 0x9B9B9B, bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (26, [S("  ", bg: 0x141414), S("╰──────────────────────────────────────────────────────────────────────────── ", fg: 0x323237, bg: 0x141414), S("Grok 4.7 (high)", fg: 0x5C5C5C, bg: 0x141414), S(" ─╯", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (27, [S("                                                                                                    ", bg: 0x141414)]),
        (28, [S("  ", bg: 0x141414), S("Ctrl+e", fg: 0xC8C8C8, bg: 0x141414), S(":expand thinking", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Space", fg: 0xC8C8C8, bg: 0x141414), S(":prompt", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Ctrl+.", fg: 0xC8C8C8, bg: 0x141414), S(":shortcuts                                    ", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414)]),
        (29, [S("                                                                                                    ", bg: 0x141414)]),
    ])

    /// Typed `fix the lint errors`, then a transcript click: 155 grey, cursor on the footer.
    static let unfocusedTypedDraftBelow = GrokCapture(cursorX: 74, cursorY: 28, rows: [
        (19, [S("  ", bg: 0x141414), S("Off by default. Opt-in to allow SpaceXAI to retain coding data, e.g.,", fg: 0x787878, bg: 0x141414), S("                             ", bg: 0x141414)]),
        (20, [S("  ", bg: 0x141414), S("prompts, traces, & metrics, for training and debugging purposes. Change", fg: 0x787878, bg: 0x141414), S("                           ", bg: 0x141414)]),
        (21, [S("  ", bg: 0x141414), S("anytime via settings.", fg: 0x787878, bg: 0x141414), S("                                                                             ", bg: 0x141414)]),
        (22, [S("  ", bg: 0x141414), S("Read Terms and Privacy Policy.", fg: 0x6C6C6C, bg: 0x141414), S("                                                                    ", bg: 0x141414)]),
        (23, [S("                                                                                                    ", bg: 0x141414)]),
        (24, [S("  ", bg: 0x141414), S("╭──────────────────────────────────────────────────────────────────────────────────────────────╮", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (25, [S("  ", bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S(" ", fg: 0x9B9B9B, bg: 0x141414), S("❯ ", fg: 0x414141, bg: 0x141414), S("fix the lint errors                                                                        ", fg: 0x9B9B9B, bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (26, [S("  ", bg: 0x141414), S("╰──────────────────────────────────────────────────────────────────────────── ", fg: 0x323237, bg: 0x141414), S("Grok 4.7 (high)", fg: 0x5C5C5C, bg: 0x141414), S(" ─╯", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (27, [S("                                                                                                    ", bg: 0x141414)]),
        (28, [S("  ", bg: 0x141414), S("Ctrl+e", fg: 0xC8C8C8, bg: 0x141414), S(":collapse thinking", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Space", fg: 0xC8C8C8, bg: 0x141414), S(":prompt", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Ctrl+.", fg: 0xC8C8C8, bg: 0x141414), S(":shortcuts                                  ", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414)]),
        (29, [S("                                                                                                    ", bg: 0x141414)]),
    ])

    /// The doorbell line pasted and not submitted, then a transcript click.
    static let unfocusedDoorbellStrandedBelow = GrokCapture(cursorX: 74, cursorY: 28, rows: [
        (19, [S("  ", bg: 0x141414), S("Off by default. Opt-in to allow SpaceXAI to retain coding data, e.g.,", fg: 0x787878, bg: 0x141414), S("                             ", bg: 0x141414)]),
        (20, [S("  ", bg: 0x141414), S("prompts, traces, & metrics, for training and debugging purposes. Change", fg: 0x787878, bg: 0x141414), S("                           ", bg: 0x141414)]),
        (21, [S("  ", bg: 0x141414), S("anytime via settings.", fg: 0x787878, bg: 0x141414), S("                                                                             ", bg: 0x141414)]),
        (22, [S("  ", bg: 0x141414), S("Read Terms and Privacy Policy.", fg: 0x6C6C6C, bg: 0x141414), S("                                                                    ", bg: 0x141414)]),
        (23, [S("                                                                                                    ", bg: 0x141414)]),
        (24, [S("  ", bg: 0x141414), S("╭──────────────────────────────────────────────────────────────────────────────────────────────╮", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (25, [S("  ", bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S(" ", fg: 0x9B9B9B, bg: 0x141414), S("❯ ", fg: 0x414141, bg: 0x141414), S("c11 mail waiting: run c11 mailbox recv --ack                                               ", fg: 0x9B9B9B, bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (26, [S("  ", bg: 0x141414), S("╰──────────────────────────────────────────────────────────────────────────── ", fg: 0x323237, bg: 0x141414), S("Grok 4.7 (high)", fg: 0x5C5C5C, bg: 0x141414), S(" ─╯", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (27, [S("                                                                                                    ", bg: 0x141414)]),
        (28, [S("  ", bg: 0x141414), S("Ctrl+e", fg: 0xC8C8C8, bg: 0x141414), S(":collapse thinking", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Space", fg: 0xC8C8C8, bg: 0x141414), S(":prompt", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Ctrl+.", fg: 0xC8C8C8, bg: 0x141414), S(":shortcuts                                  ", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414)]),
        (29, [S("                                                                                                    ", bg: 0x141414)]),
    ])

    /// A transcript click, then a hover: the hover box redraws and parks the cursor 17 rows above the composer.
    static let unfocusedPlaceholderAbove = GrokCapture(cursorX: 99, cursorY: 8, rows: [
        (0, [S("                                                                                                    ", bg: 0x141414)]),
        (1, [S("  ", bg: 0x141414), S("~/c/p/grokcap/work", fg: 0xC8C8C8, bg: 0x141414), S("                                                      ", bg: 0x141414), S("32K / 256K", fg: 0xDBDBDB, bg: 0x141414), S(" │ ", fg: 0x414141, bg: 0x141414), S("[Dashboard]", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414)]),
        (2, [S(" ", bg: 0x141414), S("┌", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x141414), S("┐", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (3, [S(" ", bg: 0x141414), S("│", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x242424), S("│", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (4, [S(" ", bg: 0x141414), S("│", fg: 0x3C3C41, bg: 0x141414), S("   ", bg: 0x242424), S("❯ ", fg: 0xC8C8C8, bg: 0x242424), S("Reply with the one word ALPHA and stop.", fg: 0xE1E1E1, bg: 0x242424), S("                                         ", bg: 0x242424), S("  2:27 AM", fg: 0x6C6C6C, bg: 0x242424), S("  ", bg: 0x242424), S("│", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (5, [S(" ", bg: 0x141414), S("│", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x242424), S("│", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (6, [S(" ", bg: 0x141414), S("└", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x141414), S("┘", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (7, [S(" ", bg: 0x141414), S("│", fg: 0x1E1E22, bg: 0x141414), S("   ", bg: 0x141414), S("ALPHA", fg: 0xC8C8C8, bg: 0x141414), S("                                                                             ", bg: 0x141414), S("  2:27 AM", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414), S("│", fg: 0x1E1E22, bg: 0x141414), S(" ", bg: 0x141414)]),
        (8, [S(" ", bg: 0x141414), S("└", fg: 0x1E1E22, bg: 0x141414), S("                                                                                                ", bg: 0x141414), S("┘", fg: 0x1E1E22, bg: 0x141414), S(" ", bg: 0x141414)]),
        (9, [S("     ", bg: 0x141414), S("Worked for 2.8s", fg: 0x6C6C6C, bg: 0x141414), S("                                                                                ", bg: 0x141414)]),
        (10, [S("                                                                                                    ", bg: 0x141414)]),
        (11, [S("                                                                                                    ", bg: 0x141414)]),
        (12, [S("                                                                                                    ", bg: 0x141414)]),
        (13, [S("                                                                                                    ", bg: 0x141414)]),
        (14, [S("                                                                                                    ", bg: 0x141414)]),
    ], bottomRows: [
        (14, [S("                                                                                                    ", bg: 0x141414)]),
        (15, [S("                                                                                                    ", bg: 0x141414)]),
        (16, [S("                                                                                                    ", bg: 0x141414)]),
        (17, [S("                                                                                                    ", bg: 0x141414)]),
        (18, [S("  ", bg: 0x141414), S("Help improve Grok", fg: 0xE1E1E1, bg: 0x141414), S("                                                             ", bg: 0x141414), S("[Opt out]", fg: 0x787878, bg: 0x141414), S(" ", bg: 0x141414), S("[Opt in]", fg: 0xE1E1E1, bg: 0x141414), S("  ", bg: 0x141414)]),
        (19, [S("  ", bg: 0x141414), S("Off by default. Opt-in to allow SpaceXAI to retain coding data, e.g.,", fg: 0x787878, bg: 0x141414), S("                             ", bg: 0x141414)]),
        (20, [S("  ", bg: 0x141414), S("prompts, traces, & metrics, for training and debugging purposes. Change", fg: 0x787878, bg: 0x141414), S("                           ", bg: 0x141414)]),
        (21, [S("  ", bg: 0x141414), S("anytime via settings.", fg: 0x787878, bg: 0x141414), S("                                                                             ", bg: 0x141414)]),
        (22, [S("  ", bg: 0x141414), S("Read Terms and Privacy Policy.", fg: 0x6C6C6C, bg: 0x141414), S("                                                                    ", bg: 0x141414)]),
        (23, [S("                                                                                                    ", bg: 0x141414)]),
        (24, [S("  ", bg: 0x141414), S("╭──────────────────────────────────────────────────────────────────────────────────────────────╮", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (25, [S("  ", bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S(" ", fg: 0x9B9B9B, bg: 0x141414), S("❯ ", fg: 0x414141, bg: 0x141414), S("Build anything", fg: 0x4E4E4E, bg: 0x141414), S("                                                                             ", fg: 0x9B9B9B, bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (26, [S("  ", bg: 0x141414), S("╰──────────────────────────────────────────────────────────────────────────── ", fg: 0x323237, bg: 0x141414), S("Grok 4.7 (high)", fg: 0x5C5C5C, bg: 0x141414), S(" ─╯", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (27, [S("                                                                                                    ", bg: 0x141414)]),
        (28, [S("  ", bg: 0x141414), S("Ctrl+e", fg: 0xC8C8C8, bg: 0x141414), S(":collapse thinking", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Space", fg: 0xC8C8C8, bg: 0x141414), S(":prompt", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Ctrl+.", fg: 0xC8C8C8, bg: 0x141414), S(":shortcuts                                  ", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414)]),
        (29, [S("                                                                                                    ", bg: 0x141414)]),
    ])

    /// Typed `fix the lint errors`, a transcript click, then a hover: cursor parked above, out of the cursor window.
    static let unfocusedTypedDraftAbove = GrokCapture(cursorX: 99, cursorY: 8, rows: [
        (0, [S("                                                                                                    ", bg: 0x141414)]),
        (1, [S("  ", bg: 0x141414), S("~/c/p/grokcap/work", fg: 0xC8C8C8, bg: 0x141414), S("                                                      ", bg: 0x141414), S("32K / 256K", fg: 0xDBDBDB, bg: 0x141414), S(" │ ", fg: 0x414141, bg: 0x141414), S("[Dashboard]", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414)]),
        (2, [S(" ", bg: 0x141414), S("┌", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x141414), S("┐", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (3, [S(" ", bg: 0x141414), S("│", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x242424), S("│", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (4, [S(" ", bg: 0x141414), S("│", fg: 0x3C3C41, bg: 0x141414), S("   ", bg: 0x242424), S("❯ ", fg: 0xC8C8C8, bg: 0x242424), S("Reply with the one word ALPHA and stop.", fg: 0xE1E1E1, bg: 0x242424), S("                                         ", bg: 0x242424), S("  2:27 AM", fg: 0x6C6C6C, bg: 0x242424), S("  ", bg: 0x242424), S("│", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (5, [S(" ", bg: 0x141414), S("│", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x242424), S("│", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (6, [S(" ", bg: 0x141414), S("└", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x141414), S("┘", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (7, [S(" ", bg: 0x141414), S("│", fg: 0x1E1E22, bg: 0x141414), S("   ", bg: 0x141414), S("ALPHA", fg: 0xC8C8C8, bg: 0x141414), S("                                                                             ", bg: 0x141414), S("  2:27 AM", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414), S("│", fg: 0x1E1E22, bg: 0x141414), S(" ", bg: 0x141414)]),
        (8, [S(" ", bg: 0x141414), S("└", fg: 0x1E1E22, bg: 0x141414), S("                                                                                                ", bg: 0x141414), S("┘", fg: 0x1E1E22, bg: 0x141414), S(" ", bg: 0x141414)]),
        (9, [S("     ", bg: 0x141414), S("Worked for 2.8s", fg: 0x6C6C6C, bg: 0x141414), S("                                                                                ", bg: 0x141414)]),
        (10, [S("                                                                                                    ", bg: 0x141414)]),
        (11, [S("                                                                                                    ", bg: 0x141414)]),
        (12, [S("                                                                                                    ", bg: 0x141414)]),
        (13, [S("                                                                                                    ", bg: 0x141414)]),
        (14, [S("                                                                                                    ", bg: 0x141414)]),
    ], bottomRows: [
        (14, [S("                                                                                                    ", bg: 0x141414)]),
        (15, [S("                                                                                                    ", bg: 0x141414)]),
        (16, [S("                                                                                                    ", bg: 0x141414)]),
        (17, [S("                                                                                                    ", bg: 0x141414)]),
        (18, [S("  ", bg: 0x141414), S("Help improve Grok", fg: 0xE1E1E1, bg: 0x141414), S("                                                             ", bg: 0x141414), S("[Opt out]", fg: 0x787878, bg: 0x141414), S(" ", bg: 0x141414), S("[Opt in]", fg: 0xE1E1E1, bg: 0x141414), S("  ", bg: 0x141414)]),
        (19, [S("  ", bg: 0x141414), S("Off by default. Opt-in to allow SpaceXAI to retain coding data, e.g.,", fg: 0x787878, bg: 0x141414), S("                             ", bg: 0x141414)]),
        (20, [S("  ", bg: 0x141414), S("prompts, traces, & metrics, for training and debugging purposes. Change", fg: 0x787878, bg: 0x141414), S("                           ", bg: 0x141414)]),
        (21, [S("  ", bg: 0x141414), S("anytime via settings.", fg: 0x787878, bg: 0x141414), S("                                                                             ", bg: 0x141414)]),
        (22, [S("  ", bg: 0x141414), S("Read Terms and Privacy Policy.", fg: 0x6C6C6C, bg: 0x141414), S("                                                                    ", bg: 0x141414)]),
        (23, [S("                                                                                                    ", bg: 0x141414)]),
        (24, [S("  ", bg: 0x141414), S("╭──────────────────────────────────────────────────────────────────────────────────────────────╮", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (25, [S("  ", bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S(" ", fg: 0x9B9B9B, bg: 0x141414), S("❯ ", fg: 0x414141, bg: 0x141414), S("fix the lint errors                                                                        ", fg: 0x9B9B9B, bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (26, [S("  ", bg: 0x141414), S("╰──────────────────────────────────────────────────────────────────────────── ", fg: 0x323237, bg: 0x141414), S("Grok 4.7 (high)", fg: 0x5C5C5C, bg: 0x141414), S(" ─╯", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (27, [S("                                                                                                    ", bg: 0x141414)]),
        (28, [S("  ", bg: 0x141414), S("Ctrl+e", fg: 0xC8C8C8, bg: 0x141414), S(":collapse thinking", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Space", fg: 0xC8C8C8, bg: 0x141414), S(":prompt", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Ctrl+.", fg: 0xC8C8C8, bg: 0x141414), S(":shortcuts                                  ", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414)]),
        (29, [S("                                                                                                    ", bg: 0x141414)]),
    ])

    /// Typed `Build anything`, a transcript click, then a hover: cursor parked above.
    static let unfocusedTypedBuildAnythingAbove = GrokCapture(cursorX: 99, cursorY: 8, rows: [
        (0, [S("                                                                                                    ", bg: 0x141414)]),
        (1, [S("  ", bg: 0x141414), S("~/c/p/grokcap/work", fg: 0xC8C8C8, bg: 0x141414), S("                                                      ", bg: 0x141414), S("32K / 256K", fg: 0xDBDBDB, bg: 0x141414), S(" │ ", fg: 0x414141, bg: 0x141414), S("[Dashboard]", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414)]),
        (2, [S(" ", bg: 0x141414), S("┌", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x141414), S("┐", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (3, [S(" ", bg: 0x141414), S("│", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x242424), S("│", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (4, [S(" ", bg: 0x141414), S("│", fg: 0x3C3C41, bg: 0x141414), S("   ", bg: 0x242424), S("❯ ", fg: 0xC8C8C8, bg: 0x242424), S("Reply with the one word ALPHA and stop.", fg: 0xE1E1E1, bg: 0x242424), S("                                         ", bg: 0x242424), S("  2:27 AM", fg: 0x6C6C6C, bg: 0x242424), S("  ", bg: 0x242424), S("│", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (5, [S(" ", bg: 0x141414), S("│", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x242424), S("│", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (6, [S(" ", bg: 0x141414), S("└", fg: 0x3C3C41, bg: 0x141414), S("                                                                                                ", bg: 0x141414), S("┘", fg: 0x3C3C41, bg: 0x141414), S(" ", bg: 0x141414)]),
        (7, [S(" ", bg: 0x141414), S("│", fg: 0x1E1E22, bg: 0x141414), S("   ", bg: 0x141414), S("ALPHA", fg: 0xC8C8C8, bg: 0x141414), S("                                                                             ", bg: 0x141414), S("  2:27 AM", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414), S("│", fg: 0x1E1E22, bg: 0x141414), S(" ", bg: 0x141414)]),
        (8, [S(" ", bg: 0x141414), S("└", fg: 0x1E1E22, bg: 0x141414), S("                                                                                                ", bg: 0x141414), S("┘", fg: 0x1E1E22, bg: 0x141414), S(" ", bg: 0x141414)]),
        (9, [S("     ", bg: 0x141414), S("Worked for 2.8s", fg: 0x6C6C6C, bg: 0x141414), S("                                                                                ", bg: 0x141414)]),
        (10, [S("                                                                                                    ", bg: 0x141414)]),
        (11, [S("                                                                                                    ", bg: 0x141414)]),
        (12, [S("                                                                                                    ", bg: 0x141414)]),
        (13, [S("                                                                                                    ", bg: 0x141414)]),
        (14, [S("                                                                                                    ", bg: 0x141414)]),
    ], bottomRows: [
        (14, [S("                                                                                                    ", bg: 0x141414)]),
        (15, [S("                                                                                                    ", bg: 0x141414)]),
        (16, [S("                                                                                                    ", bg: 0x141414)]),
        (17, [S("                                                                                                    ", bg: 0x141414)]),
        (18, [S("  ", bg: 0x141414), S("Help improve Grok", fg: 0xE1E1E1, bg: 0x141414), S("                                                             ", bg: 0x141414), S("[Opt out]", fg: 0x787878, bg: 0x141414), S(" ", bg: 0x141414), S("[Opt in]", fg: 0xE1E1E1, bg: 0x141414), S("  ", bg: 0x141414)]),
        (19, [S("  ", bg: 0x141414), S("Off by default. Opt-in to allow SpaceXAI to retain coding data, e.g.,", fg: 0x787878, bg: 0x141414), S("                             ", bg: 0x141414)]),
        (20, [S("  ", bg: 0x141414), S("prompts, traces, & metrics, for training and debugging purposes. Change", fg: 0x787878, bg: 0x141414), S("                           ", bg: 0x141414)]),
        (21, [S("  ", bg: 0x141414), S("anytime via settings.", fg: 0x787878, bg: 0x141414), S("                                                                             ", bg: 0x141414)]),
        (22, [S("  ", bg: 0x141414), S("Read Terms and Privacy Policy.", fg: 0x6C6C6C, bg: 0x141414), S("                                                                    ", bg: 0x141414)]),
        (23, [S("                                                                                                    ", bg: 0x141414)]),
        (24, [S("  ", bg: 0x141414), S("╭──────────────────────────────────────────────────────────────────────────────────────────────╮", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (25, [S("  ", bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S(" ", fg: 0x9B9B9B, bg: 0x141414), S("❯ ", fg: 0x414141, bg: 0x141414), S("Build anything                                                                             ", fg: 0x9B9B9B, bg: 0x141414), S("│", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (26, [S("  ", bg: 0x141414), S("╰──────────────────────────────────────────────────────────────────────────── ", fg: 0x323237, bg: 0x141414), S("Grok 4.7 (high)", fg: 0x5C5C5C, bg: 0x141414), S(" ─╯", fg: 0x323237, bg: 0x141414), S("  ", bg: 0x141414)]),
        (27, [S("                                                                                                    ", bg: 0x141414)]),
        (28, [S("  ", bg: 0x141414), S("Ctrl+e", fg: 0xC8C8C8, bg: 0x141414), S(":collapse thinking", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Space", fg: 0xC8C8C8, bg: 0x141414), S(":prompt", fg: 0x6C6C6C, bg: 0x141414), S("  │  ", faint: true, fg: 0x6C6C6C, bg: 0x141414), S("Ctrl+.", fg: 0xC8C8C8, bg: 0x141414), S(":shortcuts                                  ", fg: 0x6C6C6C, bg: 0x141414), S("  ", bg: 0x141414)]),
        (29, [S("                                                                                                    ", bg: 0x141414)]),
    ])

}
