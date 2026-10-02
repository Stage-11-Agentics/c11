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

    func testCodexAndHistoricalPromptTextRemainUnknown() {
        let codex = region([
            Row(y: 0, spans: [Span(text: "› "), Span(text: "Ask Codex to do anything", faint: true)]),
        ], cursorY: 0)
        XCTAssertEqual(PromptInputClassifier.classify(codex).state, .unknown)

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
