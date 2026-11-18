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

    func testPassiveClaudeTipBelowComposerDoesNotHideEmptyPromptOrDraft() {
        for draft in ["", "operator unfinished text"] {
            let input = region([
                Row(y: 0, spans: [Span(text: rule)]),
                Row(y: 1, spans: [Span(text: "❯\u{00A0}" + draft)]),
                Row(y: 2, spans: [Span(text: rule)]),
                Row(y: 3, spans: [Span(text: "Heads up · Claude Code tip")]),
                Row(y: 4, spans: [Span(text: "1: Learn more  2: Knew this already  0: Dismiss")]),
            ], cursorY: 1)
            XCTAssertEqual(PromptInputClassifier.classify(input, harness: "claude-code").state,
                           draft.isEmpty ? .empty : .draft)
        }
    }

    /// C11H-298 (repair 1b): in the incident Claude's "Heads up" tip sat above the composer. It must not hide
    /// an empty prompt or a draft there either, or a send would fall to `prompt_unknown` and never be confirmed.
    func testPassiveClaudeTipAboveComposerDoesNotHideEmptyPromptOrDraft() {
        let strips: [[String]] = [
            ["Heads up · Claude Code tip", "1: Learn more  2: Knew this already  0: Dismiss"],
            ["Heads up · 1: Learn more 2: Knew this already 0: Dismiss"],
        ]
        for strip in strips {
            for draft in ["", "Read /tmp/brief.md and follow it exactly."] {
                var rows = strip.enumerated().map { Row(y: $0.offset, spans: [Span(text: $0.element)]) }
                let top = rows.count
                rows += [
                    Row(y: top, spans: [Span(text: rule)]),
                    Row(y: top + 1, spans: [Span(text: "❯\u{00A0}" + draft)]),
                    Row(y: top + 2, spans: [Span(text: rule)]),
                ]
                XCTAssertEqual(PromptInputClassifier.classify(region(rows, cursorY: top + 1), harness: "claude-code").state,
                               draft.isEmpty ? .empty : .draft, "\(strip) draft=\(!draft.isEmpty)")
            }
        }
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

    /// Recorded from Claude Code in a fresh folder (c11, 2026-11-01): the 99-column
    /// folder-trust screen with `No, exit` highlighted. The capture window keeps the
    /// last 16 rows and the cursor sits on the selected option, as in the other
    /// recorded chooser fixtures. Row text is as drawn, including the wrapped path.
    private func recordedTrustScreen(selected: Int) -> PromptRegionSnapshot {
        let no = selected == 0 ? " \u{276F} No, exit" : "   No, exit"
        let yes = selected == 1 ? " \u{276F} Yes, I trust this folder" : "   Yes, I trust this folder"
        let texts = [
            " /private/tmp/claude-501/scratchpad/trustdir-97792/with/a/long/path/that/the/dialog/wr",
            " aps/onto/a/second/row",
            "",
            " Quick safety check: Is this a project you created or one you trust? (Like your own code, a",
            " well-known open source project, or work from your team). If not, take a moment to review what's",
            " in this folder first.",
            "",
            " Claude Code'll be able to read, edit, and execute files here.",
            "",
            " Security guide",
            "",
            no,
            yes,
            "",
            " Enter to confirm \u{00B7} Esc to cancel",
            "",
        ]
        return region(texts.enumerated().map { Row(y: $0.offset, spans: [Span(text: $0.element)]) }, cursorY: 11 + selected)
    }

    func testRecordedClaudeTrustScreenIsATrustDialogWhicheverOptionIsHighlighted() {
        for selected in [0, 1] {
            let screen = recordedTrustScreen(selected: selected)
            XCTAssertEqual(PromptInputClassifier.classify(screen, harness: "claude-code").state, .dialog, "selected \(selected)")
            XCTAssertEqual(PromptInputClassifier.chooserKind(screen, harness: "claude-code"), .trust, "selected \(selected)")
            // A launch that has not learned the harness yet still refuses.
            XCTAssertEqual(PromptInputClassifier.chooserKind(screen, harness: nil), .trust, "selected \(selected)")
        }
    }

    func testEveryRouteThatTypesRefusesTheRecordedTrustScreen() {
        // `send`, `feed answer` and the mailbox doorbell all decide from the
        // classified state; none of them may deliver (or press Return) on a dialog.
        let state = PromptInputClassifier.classify(recordedTrustScreen(selected: 0), harness: "claude-code").state
        XCTAssertEqual(state, .dialog)
        XCTAssertEqual(SendInputGuard.decide(state: state, allowUnguarded: false), .refuse(reason: "dialog"))
        XCTAssertFalse(FeedAnswerPromptCommit.admits(state))
        XCTAssertEqual(FeedAnswerPromptCommit.refusalReason(state), "dialog")
        // The doorbell: no ring is decided, and nothing presses Return after a paste.
        var input = MailboxDoorbell.Input(hasUnread: true, prompt: state)
        input.now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(MailboxDoorbell.decide(input), .skip(reason: "dialog"))
        let preReturn = MailboxDoorbellSequence.preReturn(
            rowIsCurrent: true, operatorInputUnchanged: true, agentOwnsTerminal: true,
            captured: true, prompt: state, composer: nil)
        XCTAssertNotNil(preReturn, "a dialog must refuse the doorbell's Return")
        if case .submitted? = preReturn { XCTFail("a dialog must never reach a submitted Return") }
    }

    func testDialogKindNamesThePlanChooserAndNothingElse() {
        let plan = region([
            Row(y: 0, spans: [Span(text: "Would you like to make this plan?")]),
            Row(y: 1, spans: [Span(text: "\u{276F} Yes, implement this plan")]),
            Row(y: 2, spans: [Span(text: "  No, keep planning")]),
            Row(y: 3, spans: [Span(text: "Enter to select \u{00B7} Esc to go back")]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.chooserKind(plan, harness: "claude-code"), .plan)

        let composer = region([
            Row(y: 0, spans: [Span(text: rule)]),
            Row(y: 1, spans: [Span(text: "\u{276F}\u{00A0} ")]),
            Row(y: 2, spans: [Span(text: rule)]),
        ], cursorY: 1)
        XCTAssertNil(PromptInputClassifier.chooserKind(composer, harness: "claude-code"))

        // The old chooser still on screen above a live composer is not a dialog.
        let stale = region([
            Row(y: 0, spans: [Span(text: "\u{276F} No, exit")]),
            Row(y: 1, spans: [Span(text: "  Yes, I trust this folder")]),
            Row(y: 2, spans: [Span(text: "Enter to confirm \u{00B7} Esc to cancel")]),
            Row(y: 3, spans: [Span(text: rule)]),
            Row(y: 4, spans: [Span(text: "\u{276F}\u{00A0} ")]),
        ], cursorY: 4)
        XCTAssertNil(PromptInputClassifier.chooserKind(stale, harness: "claude-code"))
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

    func testCapturedSupervisorPermissionMenusRequireLiveMenuAndMatchingHarness() {
        let menus: [(String, [String])] = [
            ("codex", ["Would you like to run the following command?", "$ touch /tmp/proof",
                       "› 1. Yes, proceed (y)", "  2. Yes, and don't ask again for commands that start with touch",
                       "  3. No, and tell Codex what to do differently (esc)",
                       "Press enter to confirm or esc to cancel"]),
            ("claude-code", ["Do you want to proceed?", "❯ 1. Yes", "  2. Yes, and always allow access",
                             "  3. Yes, and switch to auto mode", "  4. No", "Esc to cancel · Tab to amend"]),
            ("opencode", ["┃ △ Permission required", "┃ $ touch /tmp/proof", "┃ Allow once   Allow always   Reject",
                          "┃ ctrl+f fullscreen  ⇆ select  enter confirm"]),
        ]
        for (harness, menu) in menus {
            func capture(_ values: [String], cursor: Int) -> PromptRegionSnapshot {
                region(values.enumerated().map { Row(y: $0.offset, spans: [Span(text: $0.element)]) }, cursorY: cursor)
            }
            let input = capture(menu, cursor: menu.count - 1)
            let result = PromptInputClassifier.classify(input, harness: harness)
            XCTAssertEqual(result.state, .dialog, harness)
            XCTAssertEqual(result.dialogKind, "permission", harness)
            XCTAssertNil(PromptInputClassifier.composerText(input, harness: harness))
            XCTAssertNotEqual(PromptInputClassifier.classify(input, harness: "unsupported").state, .dialog)
            XCTAssertNotEqual(PromptInputClassifier.classify(capture(Array(menu.dropLast()), cursor: 1), harness: harness).state, .dialog)
            let stale = menu + ["", "❯ operator draft"]
            XCTAssertNotEqual(PromptInputClassifier.classify(capture(stale, cursor: stale.count - 1), harness: harness).state, .dialog)
        }
    }

    func testCapturedPiChooserWithHiddenCursorAndStaleOrPartialNegatives() {
        let menu = [rule, "C11-519 choice capture", "→ Allow proof", "  Cancel proof",
                    "↑↓ navigate  enter select  escape/ctrl+c cancel", rule, "~/c11-sandbox/work", "0.0%/200k (auto) fixture"]
        let input = region(menu.enumerated().map { Row(y: $0.offset, spans: [Span(text: $0.element)]) }, cursorY: 0)
        XCTAssertEqual(PromptInputClassifier.classify(input, harness: "pi", forSupervisor: true).dialogKind, "choice")
        var hidden = region([Row(y: 30, spans: [Span(text: "hidden cursor")])], cursorY: 30)
        hidden.screenBottom = .init(complete: true, rows: input.rows, cells: input.cells, text: input.text)
        XCTAssertEqual(PromptInputClassifier.classify(hidden, harness: "pi", forSupervisor: true).state, .dialog)
        hidden.screenBottom = .init(complete: false, rows: input.rows, cells: input.cells, text: input.text)
        XCTAssertNotEqual(PromptInputClassifier.classify(hidden, harness: "pi", forSupervisor: true).state, .dialog)
        let stale = menu + ["❯ operator draft"]
        let old = region(stale.enumerated().map { Row(y: $0.offset, spans: [Span(text: $0.element)]) }, cursorY: stale.count - 1)
        XCTAssertNotEqual(PromptInputClassifier.classify(old, harness: "pi", forSupervisor: true).state, .dialog)
        XCTAssertNotEqual(PromptInputClassifier.classify(input, harness: "codex").state, .dialog)
    }

    func testPiSupervisorChooserDoesNotChangeNormalComposerOrDoorbellObservation() {
        let menu = [rule, "C11-519 choice capture", "→ Allow proof", "  Cancel proof",
                    "↑↓ navigate  enter select  escape/ctrl+c cancel", rule, "~/c11-sandbox/work", "0.0%/200k (auto) fixture"]
        let chooser = region(menu.enumerated().map { Row(y: $0.offset, spans: [Span(text: $0.element)]) }, cursorY: 0)
        for (text, expected) in [("", PromptInputState.empty), ("operator draft", .draft)] {
            var composer = region([Row(y: 0, spans: [Span(text: rule)]),
                                   Row(y: 1, spans: [Span(text: text)]),
                                   Row(y: 2, spans: [Span(text: rule)])], cursorY: 1)
            composer.screenBottom = .init(complete: true, rows: chooser.rows, cells: chooser.cells, text: chooser.text)
            XCTAssertEqual(PromptInputObservation.activeScreen(composer, harness: "pi").classification.state, expected)
            XCTAssertEqual(PromptInputClassifier.composerText(composer, harness: "pi"), text.isEmpty ? nil : text)
            XCTAssertEqual(PromptInputClassifier.classify(composer, harness: "pi", forSupervisor: true).state, .dialog)
        }
        XCTAssertFalse(PromptInputClassifier.readsScreenBottom(harness: "pi"))
        XCTAssertTrue(PromptInputClassifier.readsScreenBottom(harness: " Pi ", forSupervisor: true))
        XCTAssertTrue(PromptInputClassifier.readsScreenBottom(harness: "grok"))
        for harness in ["claude-code", "codex", "opencode", "omp", nil] as [String?] {
            XCTAssertFalse(PromptInputClassifier.readsScreenBottom(harness: harness, forSupervisor: true))
        }
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
            flag: .raise("original", kind: nil),
            now: originalEpoch
        )
        _ = try store.mutateAttention(workspaceId: workspaceID, surfaceId: panelID, flag: .lower)
        _ = try store.mutateAttention(
            workspaceId: workspaceID,
            surfaceId: panelID,
            flag: .raise("replacement", kind: nil),
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

    func testOpenCodeClippedRealPlaceholderRingsButUnfinishedDraftDoesNot() {
        func capture(_ text: String, cursorX: Int) -> PromptRegionSnapshot {
            let value = region([
                Row(y: 0, spans: [Span(text: "  ┃")]),
                Row(y: 1, spans: [Span(text: "  ┃  " + text)]),
                Row(y: 2, spans: [Span(text: "  ┃")]),
                Row(y: 3, spans: [Span(text: "  ┃  Build · Fixture Fixture")]),
                Row(y: 4, spans: [Span(text: "  ╹" + String(repeating: "▀", count: 54))]),
            ], cursorY: 1)
            return PromptRegionSnapshot(cursorX: cursorX, cursorY: value.cursorY, cursorPendingWrap: false,
                complete: true, rows: value.rows, cells: value.cells, text: value.text)
        }
        let real = "Ask anything… \"What is the tech stack of this pr"
        let state = PromptInputClassifier.classify(capture(real, cursorX: 5), harness: "opencode").state
        XCTAssertEqual(state, .suggestion)
        var input = MailboxDoorbell.Input()
        input.prompt = state
        XCTAssertEqual(MailboxDoorbell.decide(input), .ring)
        XCTAssertEqual(PromptInputClassifier.classify(capture(real, cursorX: 20), harness: "opencode").state, .draft)
        XCTAssertEqual(PromptInputClassifier.classify(capture("Ask anything… \"operator draft", cursorX: 5), harness: "opencode").state, .draft)
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

    /// C11H-272 (2026-11-13, panels 1927, 1928, 1933): a stray pkill ended
    /// three Codex seats and their zsh lived on. Codex's composer row, with
    /// zsh's `terminated` line written over it, sat above the bare prompt,
    /// and input-state read the whole stretch as a 281-character draft, so
    /// every send was refused. With the shell in front only the prompt's own
    /// line counts.
    private func deadCodexAboveShellPrompt() -> PromptRegionSnapshot {
        region([
            Row(y: 0, spans: [Span(text: "• Gate passed; PR #356 is up.")]),
            Row(y: 1, spans: [Span(text: "")]),
            Row(y: 2, spans: [Span(text: "› zsh: terminated  codex --dangerously-bypass-approvals-and-sandbox")]),
            Row(y: 3, spans: [Span(text: "demo@mac work % ")]),
        ], cursorY: 3)
    }

    func testDeadAgentComposerAboveAShellPromptIsNotADraft() {
        let screen = deadCodexAboveShellPrompt()
        let state = PromptInputClassifier.classify(screen, harness: "shell").state
        XCTAssertEqual(state, .unknown)
        XCTAssertEqual(SendInputGuard.decide(state: state, allowUnguarded: false), .deliver(.unknown))
        XCTAssertEqual(PromptInputObservation.activeScreen(screen, harness: " Shell ").classification.state, .unknown)
        XCTAssertNil(PromptInputClassifier.composerText(screen, harness: "shell"))
        // An untyped panel may hide a running agent, so it keeps the wide scan.
        XCTAssertEqual(PromptInputClassifier.classify(screen, harness: nil).state, .draft)
    }

    /// The shell's own line keeps the refusal reader, soft wraps included.
    func testAShellDraftOnThePromptLineStillRefuses() {
        let typed = region([
            Row(y: 0, spans: [Span(text: "› zsh: terminated  codex --yolo")]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}git st")]),
        ], cursorY: 1)
        XCTAssertEqual(PromptInputClassifier.classify(typed, harness: "shell"), .init(state: .draft, draftLength: 6))
        let wrapped = region([
            Row(y: 0, spans: [Span(text: "› zsh: terminated  codex --yolo")]),
            Row(y: 1, spans: [Span(text: "❯\u{00A0}git commit -m 'a long ")], softWrap: true),
            Row(y: 2, spans: [Span(text: "message'")], wrapContinuation: true),
        ], cursorY: 2)
        XCTAssertEqual(PromptInputClassifier.classify(wrapped, harness: "shell"), .init(state: .draft, draftLength: 30))
        XCTAssertEqual(PromptInputClassifier.composerText(wrapped, harness: "shell"), "git commit -m 'a long message'")
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

// MARK: - C11H-280 Claude Code's composer on narrow and wide panels

/// Real Claude Code 2.1.325 screens. The 99x35 ones ran in a c11 panel under
/// `script`; the 348x86 ones in a pty of that size, the width of a full-width
/// c11 panel. The raw bytes were replayed into cells, and each fixture is what
/// the native reader returns: the cursor window (9 rows above the cursor, 6
/// below) and, on the wide screens, the bottom window, both under the
/// 4096-cell budget. Claude draws its suggested next prompt SGR 2 with the
/// cursor on its first cell, and typed text upright.
final class ClaudePromptSuggestionTests: XCTestCase {
    func testNarrowCapturesClassify() {
        XCTAssertEqual(PromptInputClassifier.classify(ClaudeCaptures.narrowEmpty.region(), harness: "claude-code"),
                       .init(state: .empty, draftLength: nil))
        let suggestion = ClaudeCaptures.narrowSuggestion.region()
        XCTAssertEqual(PromptInputClassifier.classify(suggestion, harness: "claude-code"),
                       .init(state: .suggestion, draftLength: nil))
        XCTAssertNil(PromptInputClassifier.composerText(suggestion, harness: "claude-code"))
        for (capture, text) in [(ClaudeCaptures.narrowDraft, "status check"),
                                (ClaudeCaptures.narrowTypedOverSuggestion, "x")] {
            let region = capture.region()
            XCTAssertEqual(PromptInputClassifier.classify(region, harness: "claude-code").state, .draft, text)
            XCTAssertEqual(PromptInputClassifier.composerText(region, harness: "claude-code"), text)
        }
    }

    /// The reported hold. A wide panel's cursor window passes the cell budget,
    /// so that read alone is incomplete and the box is `unknown`.
    func testWideCursorReadAloneIsUnknown() {
        for capture in [ClaudeCaptures.wideEmpty, ClaudeCaptures.wideSuggestion, ClaudeCaptures.wideDraft] {
            let region = capture.region(dropBottom: true)
            XCTAssertFalse(region.complete)
            XCTAssertEqual(PromptInputClassifier.classify(region, harness: "claude-code").state, .unknown)
        }
    }

    func testWideEmptyAndSuggestionRingAndAdmitSend() {
        for (capture, expected) in [(ClaudeCaptures.wideEmpty, PromptInputState.empty),
                                    (ClaudeCaptures.wideSuggestion, .suggestion)] {
            let region = capture.region()
            let state = PromptInputClassifier.classify(region, harness: "claude-code").state
            XCTAssertEqual(state, expected)
            XCTAssertNil(PromptInputClassifier.composerText(region, harness: "claude-code"))
            XCTAssertEqual(MailboxDoorbell.decide(.init(prompt: state)), .ring)
            XCTAssertEqual(SendInputGuard.decide(state: state, allowUnguarded: false), .deliver(.checked))
            XCTAssertTrue(FeedAnswerPromptCommit.admits(state))
        }
    }

    func testWideDraftsHold() {
        let cases: [(ClaudeCapture, String)] = [
            (ClaudeCaptures.wideDraft, "status check"),
            (ClaudeCaptures.wideTypedOverSuggestion, "x"),
            (ClaudeCaptures.wideSuggestionShapedDraft, "yes, read the next file"),
        ]
        for (capture, text) in cases {
            let region = capture.region()
            let state = PromptInputClassifier.classify(region, harness: "claude-code").state
            XCTAssertEqual(state, .draft, text)
            XCTAssertEqual(PromptInputClassifier.composerText(region, harness: "claude-code"), text)
            XCTAssertEqual(MailboxDoorbell.decide(.init(prompt: state)), .skip(reason: "draft"))
            XCTAssertEqual(SendInputGuard.decide(state: state, allowUnguarded: false), .refuse(reason: "draft"))
        }
    }

    /// Fail closed: without the faint bit the suggestion's words are typed text.
    func testSuggestionWithoutTheFaintSignalIsADraft() {
        for (capture, text) in [(ClaudeCaptures.narrowSuggestion, "yes, look at AttentionOrder.swift"),
                                (ClaudeCaptures.wideSuggestion, "yes")] {
            let region = capture.region(dropFaint: true)
            XCTAssertEqual(PromptInputClassifier.classify(region, harness: "claude-code").state, .draft, text)
            XCTAssertEqual(PromptInputClassifier.composerText(region, harness: "claude-code"), text)
        }
    }

    /// A bottom window the budget cut is no better than the clipped cursor read.
    func testIncompleteBottomWindowStaysUnknown() {
        let region = ClaudeCaptures.wideSuggestion.region(bottomIncomplete: true)
        XCTAssertEqual(PromptInputClassifier.classify(region, harness: "claude-code").state, .unknown)
    }

    /// The bottom window replaces only a clipped read. A complete cursor read
    /// is classified as it is, even when a bottom window rides along.
    func testCompleteCursorReadIsNotReplaced() {
        var region = ClaudeCaptures.narrowEmpty.region()
        region.screenBottom = ClaudeCaptures.wideDraft.region().screenBottom
        XCTAssertEqual(PromptInputClassifier.classify(region, harness: "claude-code").state, .empty)
    }

    /// Grok (its own bottom rules) and panels with no composer reader keep
    /// the clipped read.
    func testOtherHarnessesKeepTheClippedRead() {
        for harness in ["grok", "omp", nil] as [String?] {
            XCTAssertEqual(PromptInputClassifier.classify(ClaudeCaptures.wideSuggestion.region(), harness: harness).state,
                           .unknown, harness ?? "untyped")
        }
    }

    /// The capture takes the second native read only after a clipped cursor
    /// read on a bottom-composer panel; narrow panels read once.
    func testBottomReadFollowsOnlyAClippedClaudeRead() {
        let wide = ClaudeCaptures.wideSuggestion.region(dropBottom: true)
        let narrow = ClaudeCaptures.narrowSuggestion.region()
        XCTAssertTrue(PromptInputClassifier.readsScreenBottom(harness: "claude-code", afterCursorRead: wide))
        XCTAssertFalse(PromptInputClassifier.readsScreenBottom(harness: "claude-code", afterCursorRead: narrow))
        for harness in ["codex", "opencode", "pi"] {
            XCTAssertTrue(PromptInputClassifier.readsScreenBottom(harness: harness, afterCursorRead: wide), harness)
        }
        XCTAssertFalse(PromptInputClassifier.readsScreenBottom(harness: "grok", afterCursorRead: wide))
        XCTAssertFalse(PromptInputClassifier.readsScreenBottom(harness: nil, afterCursorRead: wide))
    }

    /// Through the capture the app runs, with each native window replayed
    /// from the real screen. A Claude panel always takes the bottom read too
    /// (C11H-320: its blocking dialogs hide the cursor); other harnesses read
    /// once unless clipped.
    @MainActor
    func testCaptureTakesTheBottomReadAfterAClippedClaudeRead() {
        let cases: [(ClaudeCapture, String, [TerminalController.PromptRegionAnchor], PromptInputState)] = [
            (ClaudeCaptures.wideSuggestion, "claude-code", [.cursor, .bottom], .suggestion),
            (ClaudeCaptures.wideEmpty, "claude-code", [.cursor, .bottom], .empty),
            (ClaudeCaptures.wideDraft, "claude-code", [.cursor, .bottom], .draft),
            (ClaudeCaptures.narrowSuggestion, "claude-code", [.cursor, .bottom], .suggestion),
            (ClaudeCaptures.wideSuggestion, "omp", [.cursor], .unknown),
        ]
        for (capture, harness, expectedReads, expected) in cases {
            var reads: [TerminalController.PromptRegionAnchor] = []
            let region = TerminalController.capturePromptInputRegion(harness: harness, forSupervisor: false) { anchor in
                reads.append(anchor)
                return anchor == .cursor ? capture.cursorRead() : capture.bottomRead()
            }
            let state = region.map { PromptInputClassifier.classify($0, harness: harness).state }
            XCTAssertEqual(reads, expectedReads, "\(harness) \(expected)")
            XCTAssertEqual(state, expected, "\(harness)")
            if let state, expected != .draft, expected != .unknown {
                XCTAssertEqual(MailboxDoorbell.decide(.init(prompt: state)), .ring)
                XCTAssertEqual(SendInputGuard.decide(state: state, allowUnguarded: false), .deliver(.checked))
            }
        }
    }
}

// MARK: - C11H-280 Codex, OpenCode and Pi composers on wide panels

/// Real 348x86 screens, each idle after one turn: Codex CLI 0.167.1, OpenCode
/// 2.0.25 and Pi 1.5.0, recorded by scripts/prompt-capture/capture.py. Their
/// composers sit within the bottom 11 rows, so on a full-width panel the
/// clipped cursor read is `unknown` and the bottom read classifies the box.
final class WideComposerCaptureTests: XCTestCase {
    /// Through the capture the app runs: each takes the bottom read after the
    /// clipped cursor read, an empty box rings and passes `send`'s guard, and
    /// a typed box holds with its exact text.
    @MainActor
    func testWideComposersReadFromTheBottomWindow() {
        let cases: [(String, ClaudeCapture, String, PromptInputState, String?)] = [
            ("codex", WideComposerCaptures.codexEmpty, "placeholder", .suggestion, nil),
            ("codex", WideComposerCaptures.codexTyped, "x", .draft, "x"),
            ("codex", WideComposerCaptures.codexDraft, "draft", .draft, "status check"),
            ("opencode", WideComposerCaptures.openCodeEmpty, "empty", .empty, nil),
            ("opencode", WideComposerCaptures.openCodeDraft, "draft", .draft, "status check"),
            ("pi", WideComposerCaptures.piEmpty, "empty", .empty, nil),
            ("pi", WideComposerCaptures.piDraft, "draft", .draft, "status check"),
        ]
        for (harness, capture, label, expected, text) in cases {
            let name = "\(harness) \(label)"
            XCTAssertEqual(PromptInputClassifier.classify(capture.region(dropBottom: true), harness: harness).state,
                           .unknown, name)
            var reads: [TerminalController.PromptRegionAnchor] = []
            let region = TerminalController.capturePromptInputRegion(harness: harness, forSupervisor: false) { anchor in
                reads.append(anchor)
                return anchor == .cursor ? capture.cursorRead() : capture.bottomRead()
            }
            XCTAssertEqual(reads, [.cursor, .bottom], name)
            guard let region else { return XCTFail(name) }
            let state = PromptInputClassifier.classify(region, harness: harness).state
            XCTAssertEqual(state, expected, name)
            XCTAssertEqual(PromptInputClassifier.composerText(region, harness: harness), text, name)
            if expected == .draft {
                XCTAssertEqual(MailboxDoorbell.decide(.init(prompt: state)), .skip(reason: "draft"), name)
                XCTAssertEqual(SendInputGuard.decide(state: state, allowUnguarded: false), .refuse(reason: "draft"), name)
            } else {
                XCTAssertEqual(MailboxDoorbell.decide(.init(prompt: state)), .ring, name)
                XCTAssertEqual(SendInputGuard.decide(state: state, allowUnguarded: false), .deliver(.checked), name)
            }
        }
    }

    /// A draft taller than the bottom window: `status check`, then blank rows
    /// with the cursor on the last. The window holds the cursor but not the
    /// typed row, so no reader may call the box empty. OpenCode's box reached
    /// the top of the window and read `empty` before its start was required.
    @MainActor
    func testTallDraftCutAtTheTopIsNeverEmpty() {
        let cases: [(String, ClaudeCapture, String)] = [
            ("opencode", WideComposerCaptures.openCodeTallDraft348, "348"),
            ("opencode", WideComposerCaptures.openCodeTallDraft420, "420"),
            ("opencode", WideComposerCaptures.openCodeTallDraft512, "512"),
            ("codex", WideComposerCaptures.codexTallDraft, "348"),
            ("claude-code", WideComposerCaptures.claudeTallDraft, "348"),
            ("pi", WideComposerCaptures.piTallDraft, "348"),
        ]
        for (harness, capture, width) in cases {
            let name = "\(harness) \(width)"
            var reads: [TerminalController.PromptRegionAnchor] = []
            let region = TerminalController.capturePromptInputRegion(harness: harness, forSupervisor: false) { anchor in
                reads.append(anchor)
                return anchor == .cursor ? capture.cursorRead() : capture.bottomRead()
            }
            XCTAssertEqual(reads, [.cursor, .bottom], name)
            guard let region else { return XCTFail(name) }
            let state = PromptInputClassifier.classify(region, harness: harness).state
            XCTAssertEqual(state, .unknown, name)
            XCTAssertNotEqual(MailboxDoorbell.decide(.init(prompt: state)), .ring, name)
            XCTAssertFalse(FeedAnswerPromptCommit.admits(state), name)
        }
    }
}

// Generated by scripts/prompt-capture/fixtures.py (--redact on the status
// lines, which held a home path) from the pty bytes of
// scripts/prompt-capture/capture.py runs at 348x86
// (the tall OpenCode drafts also at 420x86 and 512x86).
private enum WideComposerCaptures {
    /// OpenCode at 348x86: `status check` and six blank rows, the cursor on the last.
    static let openCodeTallDraft348 = ClaudeCapture(cursorX: 5, cursorY: 80, rows: [
        (71, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (72, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (73, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (74, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("status check", fg: 0xEEEEEE, bg: 0x1E1E1E), S(r(" ", 329), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (75, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (76, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (77, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (78, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (79, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (80, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (81, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
    ], partialRow: [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K31", fg: 0xAAAAAA, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("·", fg: 0x808080, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K3.1 Pro", fg: 0xEEEEEE, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("Kimi For Coding", fg: 0x808080, bg: 0x1E1E1E), S(r(" ", 233), fg: 0xFFFFFF, bg: 0x1E1E1E)],
    bottomRows: [
        (75, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (76, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (77, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (78, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (79, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (80, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (81, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (82, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K31", fg: 0xAAAAAA, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("·", fg: 0x808080, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K3.1 Pro", fg: 0xEEEEEE, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("Kimi For Coding", fg: 0x808080, bg: 0x1E1E1E), S(r(" ", 311), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (83, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("╹", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r("▀", 343), fg: 0x1E1E1E, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
    ])
    /// OpenCode at 420x86: `status check` and six blank rows, the cursor on the last.
    static let openCodeTallDraft420 = ClaudeCapture(cursorX: 5, cursorY: 80, rows: [
        (71, [S(r(" ", 420), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (72, [S(r(" ", 420), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (73, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 415), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (74, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("status check", fg: 0xEEEEEE, bg: 0x1E1E1E), S(r(" ", 401), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (75, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 415), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (76, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 415), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (77, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 415), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (78, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 415), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (79, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 415), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
    ], partialRow: [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 313), fg: 0xFFFFFF, bg: 0x1E1E1E)],
    bottomRows: [
        (77, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 415), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (78, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 415), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (79, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 415), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (80, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 415), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (81, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 415), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (82, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K31", fg: 0xAAAAAA, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("·", fg: 0x808080, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K3.1 Pro", fg: 0xEEEEEE, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("Kimi For Coding", fg: 0x808080, bg: 0x1E1E1E), S(r(" ", 383), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (83, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("╹", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r("▀", 415), fg: 0x1E1E1E, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (84, [S("  [status line redacted]" + r(" ", 396))]),
        (85, [S(r(" ", 420), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
    ])
    /// OpenCode at 512x86: `status check` and six blank rows, the cursor on the last.
    static let openCodeTallDraft512 = ClaudeCapture(cursorX: 5, cursorY: 80, rows: [
        (71, [S(r(" ", 512), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (72, [S(r(" ", 512), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (73, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 507), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (74, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("status check", fg: 0xEEEEEE, bg: 0x1E1E1E), S(r(" ", 493), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (75, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 507), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (76, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 507), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (77, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 507), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (78, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 507), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
    ], partialRow: [],
    bottomRows: [
        (78, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 507), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (79, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 507), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (80, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 507), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (81, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 507), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (82, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K31", fg: 0xAAAAAA, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("·", fg: 0x808080, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K3.1 Pro", fg: 0xEEEEEE, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("Kimi For Coding", fg: 0x808080, bg: 0x1E1E1E), S(r(" ", 475), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (83, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("╹", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r("▀", 507), fg: 0x1E1E1E, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (84, [S("  [status line redacted]" + r(" ", 488))]),
        (85, [S(r(" ", 512), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
    ])
    /// Codex: `status check` and nine blank rows, the cursor on the last.
    static let codexTallDraft = ClaudeCapture(cursorX: 2, cursorY: 82, rows: [
        (73, [S("› status check" + r(" ", 334))]),
        (74, [S(r(" ", 348))]),
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S(r(" ", 348))]),
        (83, [S(r(" ", 348))]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S(r(" ", 348))]),
        (83, [S(r(" ", 348))]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S(r(" ", 323) + "⚠ "), S("1 warning", fg: 0xC4A767), S(" · f2 to view ")]),
    ])
    /// Claude Code: `status check` and nine blank rows, the cursor on the last.
    static let claudeTallDraft = ClaudeCapture(cursorX: 2, cursorY: 82, rows: [
        (73, [S("❯\u{00A0}status check" + r(" ", 334))]),
        (74, [S(r(" ", 348))]),
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S(r(" ", 348))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S(r(" ", 348))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S("  "), S("⏵⏵ auto mode on", fg: 0xFFC107), S(" (shift+tab to cycle) · PR", fg: 0x999999), S(" "), S("#303", fg: 0xFFC107), S(r(" ", 300))]),
    ])
    /// Pi: `status check` and nine blank rows, the cursor on the last.
    static let piTallDraft = ClaudeCapture(cursorX: 0, cursorY: 82, rows: [
        (73, [S("status check" + r(" ", 336))]),
        (74, [S(r(" ", 348))]),
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S(r(" ", 348))]),
        (83, [S(r("─", 348), fg: 0x6185CC)]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S(r(" ", 348))]),
        (83, [S(r("─", 348), fg: 0x6185CC)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S("↑18k ↓30 R9.7k CH35.2% 2.6%/1.0M (auto)" + r(" ", 285) + "(kimi) k3.1-pro • medium", fg: 0x7E888E)]),
    ])
    /// Codex: idle after a turn, the composer empty under its faint placeholder.
    static let codexEmpty = ClaudeCapture(cursorX: 2, cursorY: 82, rows: [
        (73, [S(r(" ", 348))]),
        (74, [S(r(" ", 348))]),
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S("› "), S("Ask Codex to do anything", faint: true), S(r(" ", 322))]),
        (83, [S(r(" ", 348))]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S("› "), S("Ask Codex to do anything", faint: true), S(r(" ", 322))]),
        (83, [S(r(" ", 348))]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S("  ← for agents · ? for shortcuts" + r(" ", 291) + "⚠ "), S("1 warning", fg: 0xC4A767), S(" · f2 to view ")]),
    ])
    /// Codex: `x` typed over the placeholder.
    static let codexTyped = ClaudeCapture(cursorX: 3, cursorY: 82, rows: [
        (73, [S(r(" ", 348))]),
        (74, [S(r(" ", 348))]),
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S("› x" + r(" ", 345))]),
        (83, [S(r(" ", 348))]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S("› x" + r(" ", 345))]),
        (83, [S(r(" ", 348))]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S(r(" ", 323) + "⚠ "), S("1 warning", fg: 0xC4A767), S(" · f2 to view ")]),
    ])
    /// Codex: `status check` typed.
    static let codexDraft = ClaudeCapture(cursorX: 14, cursorY: 82, rows: [
        (73, [S(r(" ", 348))]),
        (74, [S(r(" ", 348))]),
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S("› status check" + r(" ", 334))]),
        (83, [S(r(" ", 348))]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r(" ", 348))]),
        (82, [S("› status check" + r(" ", 334))]),
        (83, [S(r(" ", 348))]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S(r(" ", 323) + "⚠ "), S("1 warning", fg: 0xC4A767), S(" · f2 to view ")]),
    ])
    /// OpenCode: idle after a turn, the composer empty.
    static let openCodeEmpty = ClaudeCapture(cursorX: 5, cursorY: 80, rows: [
        (71, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (72, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (73, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (74, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (75, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (76, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (77, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (78, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (79, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (80, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (81, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
    ], partialRow: [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K31", fg: 0xAAAAAA, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("·", fg: 0x808080, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K3.1 Pro", fg: 0xEEEEEE, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("Kimi For Coding", fg: 0x808080, bg: 0x1E1E1E), S(r(" ", 233), fg: 0xFFFFFF, bg: 0x1E1E1E)],
    bottomRows: [
        (75, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (76, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (77, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (78, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (79, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (80, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (81, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (82, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K31", fg: 0xAAAAAA, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("·", fg: 0x808080, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K3.1 Pro", fg: 0xEEEEEE, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("Kimi For Coding", fg: 0x808080, bg: 0x1E1E1E), S(r(" ", 311), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (83, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("╹", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r("▀", 343), fg: 0x1E1E1E, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
    ])
    /// OpenCode: `status check` typed.
    static let openCodeDraft = ClaudeCapture(cursorX: 17, cursorY: 80, rows: [
        (71, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (72, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (73, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (74, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (75, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (76, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (77, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (78, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (79, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (80, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("status check", fg: 0xEEEEEE, bg: 0x1E1E1E), S(r(" ", 329), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (81, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
    ], partialRow: [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K31", fg: 0xAAAAAA, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("·", fg: 0x808080, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K3.1 Pro", fg: 0xEEEEEE, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("Kimi For Coding", fg: 0x808080, bg: 0x1E1E1E), S(r(" ", 233), fg: 0xFFFFFF, bg: 0x1E1E1E)],
    bottomRows: [
        (75, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (76, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (77, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (78, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (79, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (80, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("status check", fg: 0xEEEEEE, bg: 0x1E1E1E), S(r(" ", 329), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (81, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r(" ", 343), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (82, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("┃", fg: 0xAAAAAA, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K31", fg: 0xAAAAAA, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("·", fg: 0x808080, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("K3.1 Pro", fg: 0xEEEEEE, bg: 0x1E1E1E), S(" ", fg: 0xFFFFFF, bg: 0x1E1E1E), S("Kimi For Coding", fg: 0x808080, bg: 0x1E1E1E), S(r(" ", 311), fg: 0xFFFFFF, bg: 0x1E1E1E), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (83, [S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A), S("╹", fg: 0xAAAAAA, bg: 0x0A0A0A), S(r("▀", 343), fg: 0x1E1E1E, bg: 0x0A0A0A), S("  ", fg: 0xFFFFFF, bg: 0x0A0A0A)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S(r(" ", 348), fg: 0xFFFFFF, bg: 0x0A0A0A)]),
    ])
    /// Pi: idle after a turn, the composer empty.
    static let piEmpty = ClaudeCapture(cursorX: 0, cursorY: 82, rows: [
        (73, [S(r(" ", 348), bg: 0x213B49)]),
        (74, [S(" ", bg: 0x213B49), S("Reply with the single word ok. Do not run any tools.", fg: 0xDEE0E1, bg: 0x213B49), S(r(" ", 295), bg: 0x213B49)]),
        (75, [S(r(" ", 348), bg: 0x213B49)]),
        (76, [S(r(" ", 348))]),
        (77, [S(" "), S("I'll respond single word ok no tools. Make sure response exactly ok lowercase.", italic: true, fg: 0x96A0A4), S(r(" ", 269))]),
        (78, [S(r(" ", 348))]),
        (79, [S(" ok" + r(" ", 345))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x6185CC)]),
        (82, [S(r(" ", 348))]),
        (83, [S(r("─", 348), fg: 0x6185CC)]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348), bg: 0x213B49)]),
        (76, [S(r(" ", 348))]),
        (77, [S(" "), S("I'll respond single word ok no tools. Make sure response exactly ok lowercase.", italic: true, fg: 0x96A0A4), S(r(" ", 269))]),
        (78, [S(r(" ", 348))]),
        (79, [S(" ok" + r(" ", 345))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x6185CC)]),
        (82, [S(r(" ", 348))]),
        (83, [S(r("─", 348), fg: 0x6185CC)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S("↑28k ↓29 2.6%/1.0M (auto)" + r(" ", 299) + "(kimi) k3.1-pro • medium", fg: 0x7E888E)]),
    ])
    /// Pi: `status check` typed.
    static let piDraft = ClaudeCapture(cursorX: 12, cursorY: 82, rows: [
        (73, [S(r(" ", 348), bg: 0x213B49)]),
        (74, [S(" ", bg: 0x213B49), S("Reply with the single word ok. Do not run any tools.", fg: 0xDEE0E1, bg: 0x213B49), S(r(" ", 295), bg: 0x213B49)]),
        (75, [S(r(" ", 348), bg: 0x213B49)]),
        (76, [S(r(" ", 348))]),
        (77, [S(" "), S("I'll respond single word ok no tools. Make sure response exactly ok lowercase.", italic: true, fg: 0x96A0A4), S(r(" ", 269))]),
        (78, [S(r(" ", 348))]),
        (79, [S(" ok" + r(" ", 345))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x6185CC)]),
        (82, [S("status check" + r(" ", 336))]),
        (83, [S(r("─", 348), fg: 0x6185CC)]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348), bg: 0x213B49)]),
        (76, [S(r(" ", 348))]),
        (77, [S(" "), S("I'll respond single word ok no tools. Make sure response exactly ok lowercase.", italic: true, fg: 0x96A0A4), S(r(" ", 269))]),
        (78, [S(r(" ", 348))]),
        (79, [S(" ok" + r(" ", 345))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x6185CC)]),
        (82, [S("status check" + r(" ", 336))]),
        (83, [S(r("─", 348), fg: 0x6185CC)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S("↑28k ↓29 2.6%/1.0M (auto)" + r(" ", 299) + "(kimi) k3.1-pro • medium", fg: 0x7E888E)]),
    ])
}

private struct ClaudeCapture {
    let cursorX: Int
    let cursorY: Int
    /// The cursor window's whole rows.
    let rows: [(Int, [S])]
    /// Cells of the row the cell budget cut, which the native reader returns
    /// with no row entry. Present only when the cursor read is incomplete.
    var partialRow: [S]? = nil
    /// The bottom window. The native reader drops the row the budget would
    /// cut, so this read stays complete.
    var bottomRows: [(Int, [S])]? = nil

    /// The native cursor read alone.
    func cursorRead() -> PromptRegionSnapshot { region(dropBottom: true) }

    /// The native bottom read, which reports the live cursor too. Nil when
    /// this screen was narrow enough that no bottom window was recorded.
    func bottomRead() -> PromptRegionSnapshot? {
        guard let bottom = region().screenBottom else { return nil }
        return PromptRegionSnapshot(
            cursorX: cursorX, cursorY: cursorY, cursorPendingWrap: false, complete: bottom.complete,
            rows: bottom.rows, cells: bottom.cells, text: bottom.text
        )
    }

    func region(dropBottom: Bool = false, bottomIncomplete: Bool = false, dropFaint: Bool = false) -> PromptRegionSnapshot {
        let window = Self.cells(rows, partial: partialRow, dropFaint: dropFaint)
        var snapshot = PromptRegionSnapshot(
            cursorX: cursorX,
            cursorY: cursorY,
            cursorPendingWrap: false,
            complete: partialRow == nil,
            rows: window.rows,
            cells: window.cells,
            text: window.text
        )
        if let bottomRows, !dropBottom {
            let bottom = Self.cells(bottomRows, partial: nil, dropFaint: dropFaint)
            snapshot.screenBottom = PromptRegionRows(
                complete: !bottomIncomplete, rows: bottom.rows, cells: bottom.cells, text: bottom.text
            )
        }
        return snapshot
    }

    /// One cell per scalar: these screens hold no wide or combining glyphs.
    private static func cells(
        _ rows: [(Int, [S])], partial: [S]?, dropFaint: Bool
    ) -> (rows: [PromptRegionRow], cells: [PromptRegionCell], text: Data) {
        var bytes = Data()
        var cells: [PromptRegionCell] = []
        var outputRows: [PromptRegionRow] = []
        func append(_ spans: [S]) {
            for span in spans {
                for scalar in span.text.unicodeScalars {
                    let encoded = Array(String(scalar).utf8)
                    cells.append(PromptRegionCell(
                        textOffset: bytes.count, textLength: encoded.count,
                        faint: span.faint && !dropFaint, italic: span.italic, fg: span.fg, bg: span.bg
                    ))
                    bytes.append(contentsOf: encoded)
                }
            }
        }
        for (y, spans) in rows {
            let start = cells.count
            append(spans)
            outputRows.append(PromptRegionRow(
                screenY: y, cellRange: start..<cells.count, softWrap: false, wrapContinuation: false
            ))
        }
        if let partial { append(partial) }
        return (outputRows, cells, bytes)
    }
}

private func r(_ text: String, _ count: Int) -> String { String(repeating: text, count: count) }

// Generated by scripts/prompt-capture/fixtures.py (--redact "[haiku-5.5") from
// real Claude Code 2.1.325 pty bytes: the 99x35 screens recorded with
// `script` in a c11 panel, the 348x86 ones by scripts/prompt-capture/capture.py.
// The status line under each box is redacted to its width, which the cell
// budget counts.
private enum ClaudeCaptures {
    /// 99x35, idle after a turn: an empty box.
    static let narrowEmpty = ClaudeCapture(cursorX: 2, cursorY: 31, rows: [
        (22, [S("⏺", fg: 0xFFFFFF), S(" I'm not sure what \"x\" means. Which do you want?" + r(" ", 50))]),
        (23, [S(r(" ", 99))]),
        (24, [S("  1. Yes, read "), S("AttentionOrder.swift", fg: 0xB1B9F9), S(" next. (Recommended if you meant yes to my question.)" + r(" ", 11))]),
        (25, [S("  2. Stop here. I'll leave the Feed review at "), S("SendInputGuard.swift", fg: 0xB1B9F9), S("." + r(" ", 32))]),
        (26, [S("  3. Something else. Tell me what you meant." + r(" ", 55))]),
        (27, [S(r(" ", 99))]),
        (28, [S("✻", fg: 0x999999), S(" "), S("Crunched for 1s · done 5:28 PM", fg: 0x999999), S(r(" ", 67))]),
        (29, [S(r(" ", 99))]),
        (30, [S(r("─", 99), fg: 0x888888)]),
        (31, [S("❯\u{00A0}" + r(" ", 97))]),
        (32, [S(r("─", 99), fg: 0x888888)]),
        (33, [S("  [status line redacted]" + r(" ", 75))]),
        (34, [S("  "), S("⏵⏵ auto mode on", fg: 0xFFC107), S(" (shift+tab to cycle)", fg: 0x999999), S(r(" ", 61))]),
    ])
    /// 99x35, idle after a turn: Claude's suggested next prompt, SGR 2, the cursor on its first cell.
    static let narrowSuggestion = ClaudeCapture(cursorX: 2, cursorY: 31, rows: [
        (22, [S("  panel's prompt-input state. It refuses delivery when the prompt holds a draft or a dialog is     ")]),
        (23, [S("  open, unless the caller explicitly overrides the guard, and it also checks that the target" + r(" ", 7))]),
        (24, [S("  workspace and panel are still current before writing." + r(" ", 44))]),
        (25, [S(r(" ", 99))]),
        (26, [S("  Should I look at the next file, "), S("AttentionOrder.swift", fg: 0xB1B9F9), S("?" + r(" ", 44))]),
        (27, [S(r(" ", 99))]),
        (28, [S("✻", fg: 0x999999), S(" "), S("Worked for 2s · done 5:27 PM", fg: 0x999999), S(r(" ", 69))]),
        (29, [S(r(" ", 99))]),
        (30, [S(r("─", 99), fg: 0x888888)]),
        (31, [S("❯\u{00A0}"), S("yes, look at AttentionOrder.swift", faint: true), S(r(" ", 64))]),
        (32, [S(r("─", 99), fg: 0x888888)]),
        (33, [S("  [status line redacted]" + r(" ", 75))]),
        (34, [S("  "), S("⏵⏵ auto mode on", fg: 0xFFC107), S(" (shift+tab to cycle)", fg: 0x999999), S(r(" ", 61))]),
    ])
    /// 99x35: `status check` typed into the empty box.
    static let narrowDraft = ClaudeCapture(cursorX: 14, cursorY: 31, rows: [
        (22, [S("⏺", fg: 0xFFFFFF), S(" I'm not sure what \"x\" means. Which do you want?" + r(" ", 50))]),
        (23, [S(r(" ", 99))]),
        (24, [S("  1. Yes, read "), S("AttentionOrder.swift", fg: 0xB1B9F9), S(" next. (Recommended if you meant yes to my question.)" + r(" ", 11))]),
        (25, [S("  2. Stop here. I'll leave the Feed review at "), S("SendInputGuard.swift", fg: 0xB1B9F9), S("." + r(" ", 32))]),
        (26, [S("  3. Something else. Tell me what you meant." + r(" ", 55))]),
        (27, [S(r(" ", 99))]),
        (28, [S("✻", fg: 0x999999), S(" "), S("Crunched for 1s · done 5:28 PM", fg: 0x999999), S(r(" ", 67))]),
        (29, [S(r(" ", 99))]),
        (30, [S(r("─", 99), fg: 0x888888)]),
        (31, [S("❯\u{00A0}status check" + r(" ", 85))]),
        (32, [S(r("─", 99), fg: 0x888888)]),
        (33, [S("  [status line redacted]" + r(" ", 75))]),
        (34, [S("  "), S("⏵⏵ auto mode on", fg: 0xFFC107), S(" (shift+tab to cycle)", fg: 0x999999), S(r(" ", 61))]),
    ])
    /// 99x35: one key typed over a suggestion. The suggestion is gone and `x` is upright.
    static let narrowTypedOverSuggestion = ClaudeCapture(cursorX: 3, cursorY: 31, rows: [
        (22, [S("  including the journal sequence and ask event, so a delayed Return cannot answer a later ask in   ")]),
        (23, [S("  the same tab, and it starts "), S("FeedAnswerEligibility.capture", fg: 0xB1B9F9), S(", which returns that identity only when ")]),
        (24, [S("  the workspace, owner, snapshot and projected row all check out." + r(" ", 34))]),
        (25, [S(r(" ", 99))]),
        (26, [S("  Should I read the rest of "), S("FeedAnswer.swift", fg: 0xB1B9F9), S("?" + r(" ", 54))]),
        (27, [S(r(" ", 99))]),
        (28, [S("✻", fg: 0x999999), S(" "), S("Worked for 2s · done 5:29 PM", fg: 0x999999), S(r(" ", 69))]),
        (29, [S(r(" ", 99))]),
        (30, [S(r("─", 99), fg: 0x888888)]),
        (31, [S("❯\u{00A0}x" + r(" ", 96))]),
        (32, [S(r("─", 99), fg: 0x888888)]),
        (33, [S("  [status line redacted]" + r(" ", 75))]),
        (34, [S("  "), S("⏵⏵ auto mode on", fg: 0xFFC107), S(" (shift+tab to cycle)", fg: 0x999999), S(r(" ", 61))]),
    ])
    /// 348x86, idle after a turn: an empty box.
    static let wideEmpty = ClaudeCapture(cursorX: 2, cursorY: 82, rows: [
        (73, [S(r(" ", 348))]),
        (74, [S(r(" ", 348))]),
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x888888)]),
        (82, [S("❯\u{00A0}" + r(" ", 346))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x888888)]),
        (82, [S("❯\u{00A0}" + r(" ", 346))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S("  "), S("⏵⏵ auto mode on", fg: 0xFFC107), S(" (shift+tab to cycle)", fg: 0x999999), S(r(" ", 310))]),
    ])
    /// 348x86, idle after a turn: the suggestion `yes`.
    static let wideSuggestion = ClaudeCapture(cursorX: 2, cursorY: 82, rows: [
        (73, [S(r(" ", 348))]),
        (74, [S(r(" ", 348))]),
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x888888)]),
        (82, [S("❯\u{00A0}"), S("yes", faint: true), S(r(" ", 343))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x888888)]),
        (82, [S("❯\u{00A0}"), S("yes", faint: true), S(r(" ", 343))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S("  "), S("⏵⏵ auto mode on", fg: 0xFFC107), S(" (shift+tab to cycle)", fg: 0x999999), S(r(" ", 310))]),
    ])
    /// 348x86: `x` typed over that suggestion.
    static let wideTypedOverSuggestion = ClaudeCapture(cursorX: 3, cursorY: 82, rows: [
        (73, [S(r(" ", 348))]),
        (74, [S(r(" ", 348))]),
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x888888)]),
        (82, [S("❯\u{00A0}x" + r(" ", 345))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x888888)]),
        (82, [S("❯\u{00A0}x" + r(" ", 345))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S("  "), S("⏵⏵ auto mode on", fg: 0xFFC107), S(" (shift+tab to cycle)", fg: 0x999999), S(r(" ", 310))]),
    ])
    /// 348x86: `status check` typed, the words the Orchestrator's suggestion showed on 2026-11-13.
    static let wideDraft = ClaudeCapture(cursorX: 14, cursorY: 82, rows: [
        (73, [S(r(" ", 348))]),
        (74, [S(r(" ", 348))]),
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x888888)]),
        (82, [S("❯\u{00A0}status check" + r(" ", 334))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x888888)]),
        (82, [S("❯\u{00A0}status check" + r(" ", 334))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S("  "), S("⏵⏵ auto mode on", fg: 0xFFC107), S(" (shift+tab to cycle)", fg: 0x999999), S(r(" ", 310))]),
    ])
    /// 348x86: `yes, read the next file` typed by hand, a suggestion's shape drawn upright.
    static let wideSuggestionShapedDraft = ClaudeCapture(cursorX: 25, cursorY: 82, rows: [
        (73, [S(r(" ", 348))]),
        (74, [S(r(" ", 348))]),
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x888888)]),
        (82, [S("❯\u{00A0}yes, read the next file" + r(" ", 323))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
    ], partialRow: [S("  [status line redacted]" + r(" ", 244))],
    bottomRows: [
        (75, [S(r(" ", 348))]),
        (76, [S(r(" ", 348))]),
        (77, [S(r(" ", 348))]),
        (78, [S(r(" ", 348))]),
        (79, [S(r(" ", 348))]),
        (80, [S(r(" ", 348))]),
        (81, [S(r("─", 348), fg: 0x888888)]),
        (82, [S("❯\u{00A0}yes, read the next file" + r(" ", 323))]),
        (83, [S(r("─", 348), fg: 0x888888)]),
        (84, [S("  [status line redacted]" + r(" ", 324))]),
        (85, [S("  "), S("⏵⏵ auto mode on", fg: 0xFFC107), S(" (shift+tab to cycle)", fg: 0x999999), S(r(" ", 310))]),
    ])
}

/// C11H-298: a send reports submitted only on the agent's own evidence that it took the line.
final class SendSubmitConfirmationTests: XCTestCase {
    private typealias Facts = SendSubmitConfirmation.Facts

    private func expectation(screen: Bool, isAgent: Bool = true, wantsReturn: Bool = true, bodyIsEmpty: Bool = false,
                             unguarded: Bool = false, _ baseline: Facts) -> SendSubmitConfirmation.Expectation {
        SendSubmitConfirmation.expectation(wantsReturn: wantsReturn, bodyIsEmpty: bodyIsEmpty, screen: screen,
                                           isAgent: isAgent, unguarded: unguarded, baseline: baseline)
    }

    func testAnIdleAgentWithNoScreenMustStartATurn() {
        XCTAssertEqual(expectation(screen: false, Facts(hcStatus: "idle")), .turnStart)
        XCTAssertEqual(expectation(screen: false, Facts(hcStatus: "done")), .turnStart)
    }

    func testAnEmptyComposerOnScreenMustTakeTheLine() {
        XCTAssertEqual(expectation(screen: true, Facts(prompt: .empty)), .turnStart)
        XCTAssertEqual(expectation(screen: true, Facts(prompt: .suggestion)), .turnStart)
    }

    func testNothingToWaitOnIsNamed() {
        XCTAssertEqual(expectation(screen: false, wantsReturn: false, Facts(hcStatus: "idle")), .none("no_return"))
        XCTAssertEqual(expectation(screen: false, bodyIsEmpty: true, Facts(hcStatus: "idle")), .none("bare_return"))
        XCTAssertEqual(expectation(screen: false, isAgent: false, Facts()), .none("not_agent"))
        XCTAssertEqual(expectation(screen: false, Facts(hcStatus: "working")), .none("agent_working"))
        XCTAssertEqual(expectation(screen: false, Facts(hcStatus: "idle", journalPhase: .working)), .none("agent_working"))
        XCTAssertEqual(expectation(screen: false, unguarded: true, Facts(hcStatus: "blocked")), .none("unguarded"))
        XCTAssertEqual(expectation(screen: true, Facts(prompt: .unknown)), .none("prompt_unknown"))
        XCTAssertEqual(expectation(screen: true, unguarded: true, Facts(prompt: .draft)), .none("unguarded"))
        XCTAssertEqual(SendSubmitConfirmation.expectation(wantsReturn: true, bodyIsEmpty: false, screen: false, isAgent: true,
            unguarded: false, baseline: Facts(hcStatus: "idle"), localCommand: true), .none("local_command"))
    }

    /// `/clear`, `/model opus` and `!ls` start no turn; an absolute path opening a message is a message.
    func testSlashCommandsAndShellLinesAreLocal() {
        for line in ["/clear", "/model opus", "  /compact keep the plan", "!ls -la", "/mcp:tools", "/release-notes"] {
            XCTAssertTrue(SendSubmitConfirmation.isLocalCommand(line), line)
        }
        for line in ["/Users/me/brief.md, read it", "/tmp/x.md and follow it", "Read /tmp/brief.md", "/ space", "/1abc", ""] {
            XCTAssertFalse(SendSubmitConfirmation.isLocalCommand(line), line)
        }
    }

    /// Repair 1, B1: hc can fill in the retained time of the same status and turn after a reconnect, with no
    /// input taken. The journal's idle `sinceMs` moving from 0 to 2500 for `done`, turn 9, is not a turn.
    func testATimestampFilledInLaterForTheSameTurnIsNotATurn() {
        for turnID in [nil, "9"] as [String?] {
            let before = Facts(hcStatus: "done", hcTurn: 9, journalPhase: .idle, journalSinceMs: 0, journalTurnID: turnID)
            var enriched = before; enriched.journalSinceMs = 2500
            XCTAssertEqual(SendSubmitConfirmation.judge(baseline: before, now: enriched, final: false), .pending)
            XCTAssertEqual(SendSubmitConfirmation.judge(baseline: before, now: enriched, final: true), .unconfirmed("no_turn_start"))
            // Repair 2: learning an identity the baseline did not hold (nil to "hc-9") is discovery, not a turn.
            var discovered = enriched; discovered.journalTurnID = "hc-9"
            if turnID == nil {
                XCTAssertEqual(SendSubmitConfirmation.judge(baseline: before, now: discovered, final: true),
                               .unconfirmed("no_turn_start"), "nil to hc-9 is a first look at the same turn")
            }
            var nextTurn = enriched; nextTurn.journalTurnID = "10"
            XCTAssertEqual(SendSubmitConfirmation.judge(baseline: before, now: nextTurn, final: true),
                           turnID == nil ? .unconfirmed("no_turn_start") : .confirmed("journal_turn"),
                           "only a change from an identity the baseline held is a new turn")
        }
    }

    /// Repair 2 (Astra B1): a restored or reconnected panel whose live journal is absent at the baseline and
    /// appears during the wait shows the retained turn it already had. With every hc fact unchanged (`done`,
    /// 2500, turn 9), that first look is never a submission, idle or working.
    func testAJournalFirstSeenDuringTheWaitIsNotATurn() {
        let before = Facts(hcStatus: "done", hcStatusMs: 2500, hcTurn: 9)
        var appeared = before
        appeared.journalPhase = .idle; appeared.journalSinceMs = 2500; appeared.journalTurnID = "hc-9"
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: before, now: appeared, final: false), .pending)
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: before, now: appeared, final: true), .unconfirmed("no_turn_start"))
        var retainedWorking = appeared; retainedWorking.journalPhase = .working
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: before, now: retainedWorking, final: true),
                       .unconfirmed("no_turn_start"), "a republished working phase is not this line's turn")
        var hcMoved = appeared; hcMoved.hcTurn = 10
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: before, now: hcMoved, final: false), .confirmed("hc_turn"),
                       "an independently advanced hc turn still confirms")
    }

    /// Repair 2 (Astra B2): a recognized agent owns the terminal whether or not c11 can read its composer, and
    /// for an agent JSON `submitted` is only its confirmed take.
    func testAnAgentWithoutAComposerReaderStillOwnsItsTerminal() {
        for kind in ["omp", "github-copilot", "claude-code", "codex"] {
            XCTAssertTrue(SendSubmitConfirmation.screenTargetIsAgent(harness: kind, record: nil), kind)
        }
        XCTAssertFalse(PromptInputClassifier.supportsComposer(harness: "omp"), "the case this covers")
        XCTAssertFalse(SendSubmitConfirmation.screenTargetIsAgent(harness: nil, record: nil))
        XCTAssertFalse(SendSubmitConfirmation.screenTargetIsAgent(harness: "zsh", record: nil))
        let claude = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "c", localAddress: "t1"), state: .running, labels: [:],
            machineAvailability: .local, pid: 7, foreground: HCForeground(name: "claude", argv: ["claude"]), status: "idle")
        XCTAssertTrue(SendSubmitConfirmation.screenTargetIsAgent(harness: nil, record: claude), "hc's foreground")
        XCTAssertFalse(SendSubmitConfirmation.submittedField(verdict: nil, agentOwned: true, returnWritten: true),
                       "an agent line not waited on is not reported submitted")
        XCTAssertTrue(SendSubmitConfirmation.submittedField(verdict: nil, agentOwned: false, returnWritten: true))
        XCTAssertFalse(SendSubmitConfirmation.submittedField(verdict: nil, agentOwned: false, returnWritten: false))
        XCTAssertTrue(SendSubmitConfirmation.submittedField(verdict: .confirmed("hc_status"), agentOwned: true, returnWritten: true))
        XCTAssertFalse(SendSubmitConfirmation.submittedField(verdict: .unconfirmed("dialog"), agentOwned: true, returnWritten: true))
    }

    /// Review finding 1: an empty composer read from the frame drawn before the text was typed proves nothing.
    func testAnEmptyComposerFromTheBaselineFrameIsNotEvidence() {
        let baseline = Facts(hcStatus: "idle", prompt: .empty, frame: 41)
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: baseline, now: Facts(hcStatus: "idle", prompt: .empty, frame: 41),
                                                    final: false), .pending)
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: baseline, now: Facts(hcStatus: "idle", prompt: .empty, frame: 41),
                                                    final: true), .unconfirmed("no_turn_start"))
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: baseline, now: Facts(hcStatus: "idle", prompt: .empty, frame: 42),
                                                    final: false), .confirmed("composer_empty"))
    }

    /// Review finding 2: a turn already running is the agent's own work. Its edges never confirm this line;
    /// only the composer can, and a line still in it outranks any edge.
    func testARunningTurnsOwnEdgesNeverConfirmTheLine() {
        let working = Facts(hcStatus: "working", hcStatusMs: 100, hcTurn: 3, journalPhase: .working, journalSinceMs: 50,
                            prompt: .empty, frame: 1)
        let blocked = Facts(hcStatus: "blocked", hcStatusMs: 400, hcTurn: 3, journalPhase: .blocked, journalSinceMs: 400,
                            prompt: .draft, frame: 2)
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: working, now: blocked, final: true), .unconfirmed("composer_holds_text"))
        let ended = Facts(hcStatus: "idle", hcStatusMs: 500, hcTurn: 4, journalPhase: .idle, journalSinceMs: 500,
                          prompt: .unknown, frame: 3)
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: working, now: ended, final: true), .unconfirmed("no_turn_start"))
        var queued = ended; queued.prompt = .empty
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: working, now: queued, final: false), .confirmed("composer_empty"))
        let idle = Facts(hcStatus: "idle", hcStatusMs: 100, journalPhase: .idle, journalSinceMs: 50, prompt: .empty, frame: 1)
        var started = blocked; started.prompt = .empty
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: idle, now: started, final: false), .confirmed("journal_turn"))
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: idle, now: blocked, final: true), .unconfirmed("composer_holds_text"),
                       "a turn edge with the line still in the composer is not this line")
    }

    func testTheAgentsOwnTurnConfirms() {
        let idle = Facts(hcStatus: "idle", hcStatusMs: 100, hcTurn: 4, journalPhase: .idle, journalSinceMs: 50,
                         journalTurnID: "turn-1")
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: idle,
            now: Facts(hcStatus: "idle", hcStatusMs: 100, hcTurn: 4, journalPhase: .working, journalSinceMs: 200), final: false),
            .confirmed("journal_turn"))
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: idle,
            now: Facts(hcStatus: "idle", hcStatusMs: 100, hcTurn: 4, journalPhase: .idle, journalSinceMs: 300,
                       journalTurnID: "turn-2"), final: false),
            .confirmed("journal_turn"), "a whole turn that came and went between looks, under a new turn identity")
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: idle,
            now: Facts(hcStatus: "working", hcStatusMs: 180, hcTurn: 4, journalPhase: .idle, journalSinceMs: 50), final: false),
            .confirmed("hc_status"))
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: idle,
            now: Facts(hcStatus: "idle", hcStatusMs: 100, hcTurn: 5, journalPhase: .idle, journalSinceMs: 50), final: false),
            .confirmed("hc_turn"))
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: Facts(prompt: .empty), now: Facts(prompt: .empty), final: false),
            .confirmed("composer_empty"))
    }

    /// The 2026-11-14 01:38 incident: the Return was written, hc and the journal stayed idle, and the text sat in
    /// the composer. The send must not say submitted.
    func testAnIdleAgentThatNeverTookTheLineIsUnconfirmed() {
        let idle = Facts(hcStatus: "idle", hcStatusMs: 100, journalPhase: .idle, journalSinceMs: 50)
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: idle, now: idle, final: false), .pending)
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: idle, now: idle, final: true), .unconfirmed("no_turn_start"))
        var draft = idle; draft.prompt = .draft
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: idle, now: draft, final: true), .unconfirmed("composer_holds_text"))
        var dialog = idle; dialog.prompt = .dialog
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: idle, now: dialog, final: true), .unconfirmed("dialog"))
        let working = Facts(hcStatus: "working", hcStatusMs: 100, journalPhase: .working, journalSinceMs: 50)
        XCTAssertEqual(SendSubmitConfirmation.judge(baseline: working, now: working, final: true), .unconfirmed("no_turn_start"),
                       "a turn that was already open before the send is not this send's turn")
    }

    func testTheWaitLooksUntilEvidenceOrTheDeadline() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let deadline = clock.addingTimeInterval(1)
        let baseline = Facts(hcStatus: "idle", prompt: .empty)
        var looks = 0
        let held = SendSubmitConfirmation.wait(baseline: baseline, deadline: deadline, now: { clock },
            sleep: { clock = clock.addingTimeInterval($0) }) { timeout in
            XCTAssertLessThanOrEqual(timeout, 1)
            looks += 1
            return Facts(hcStatus: "idle", prompt: .draft)
        }
        XCTAssertEqual(held, .unconfirmed("composer_holds_text"))
        XCTAssertTrue((9...10).contains(looks), "one look per 100 ms until the deadline, got \(looks)")

        clock = Date(timeIntervalSince1970: 2_000)
        looks = 0
        let taken = SendSubmitConfirmation.wait(baseline: baseline, deadline: clock.addingTimeInterval(3), now: { clock },
            sleep: { clock = clock.addingTimeInterval($0) }) { _ in
            looks += 1
            return Facts(hcStatus: looks < 3 ? "idle" : "working", hcStatusMs: Int64(looks))
        }
        XCTAssertEqual(taken, .confirmed("hc_status"))
        XCTAssertEqual(looks, 3)

        clock = Date(timeIntervalSince1970: 3_000)
        let blind = SendSubmitConfirmation.wait(baseline: baseline, deadline: clock.addingTimeInterval(0.5), now: { clock },
            sleep: { clock = clock.addingTimeInterval($0) }) { _ in nil }

        // Repair 1, B3: the wait ends at its deadline. Each look may block only for the time left, and a look
        // that uses all of it (a busy main thread) ends the wait instead of earning another poll.
        for (budget, lookTakes) in [(0.35, 1.0), (3.0, 1.0), (3.0, 0.03)] {
            let start = Date(timeIntervalSinceReferenceDate: 4_000)   // near the reference date: full precision
            clock = start
            var timeouts: [TimeInterval] = []
            let verdict = SendSubmitConfirmation.wait(baseline: baseline, deadline: start.addingTimeInterval(budget),
                now: { clock }, sleep: { clock = clock.addingTimeInterval($0) }) { timeout in
                timeouts.append(timeout); clock = clock.addingTimeInterval(min(timeout, lookTakes)); return nil
            }
            XCTAssertEqual(verdict, .unconfirmed("no_turn_start"))
            XCTAssertLessThanOrEqual(clock.timeIntervalSince(start), budget + 1e-6, "budget \(budget): \(timeouts)")
            XCTAssertTrue(timeouts.allSatisfy { $0 > 0 && $0 <= 1 }, "\(timeouts)")
        }
        XCTAssertEqual(blind, .unconfirmed("no_turn_start"), "no answer at all is not a submission")
    }

    /// The doorbell's main-actor wait: a line the composer still holds is never delivered.
    @MainActor
    func testTheDoorbellWaitHoldsALineTheComposerKeeps() async {
        let baseline = Facts(hcStatus: "idle", prompt: .empty)
        let held = await SendSubmitConfirmation.waitOnMain(baseline: baseline, deadline: Date().addingTimeInterval(0.3)) {
            Facts(hcStatus: "idle", prompt: .draft)
        }
        XCTAssertEqual(held, .unconfirmed("composer_holds_text"))
        let taken = await SendSubmitConfirmation.waitOnMain(baseline: baseline, deadline: Date().addingTimeInterval(2)) {
            Facts(hcStatus: "idle", prompt: .empty)
        }
        XCTAssertEqual(taken, .confirmed("composer_empty"))
    }

    /// C11H-305: a look the waiting thread gave up on never runs its capture later, however late main gets to it.
    func testALookThatTimedOutNeverRunsItsCapture() {
        nonisolated(unsafe) var parked: (@Sendable () -> Void)?
        nonisolated(unsafe) var captures = 0
        let facts = SendSubmitConfirmation.timedLook(timeout: 0.02, schedule: { parked = $0 }) {
            captures += 1
            return Facts(hcStatus: "working")
        }
        XCTAssertNil(facts, "no answer inside the bound")
        parked?()  // main reaches the queued look only now
        XCTAssertEqual(captures, 0, "a cancelled look is dropped at its top")
        let answered = SendSubmitConfirmation.timedLook(timeout: 1, schedule: { work in
            DispatchQueue.global().async { work() }
        }) { Facts(hcStatus: "idle") }
        XCTAssertEqual(answered?.hcStatus, "idle", "a look in time answers")
    }
}
