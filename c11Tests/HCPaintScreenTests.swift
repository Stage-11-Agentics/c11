import Foundation
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-306: a headless panel's composer, read from hc's paint. hc's `terminal.attach` with `observe: true` starts
/// with the core's own screen rendered by Ghostty's VT formatter; `HCPaintScreen` replays it and the screen path's
/// classifier reads it. The paints here follow hc's shape (`viewers.rs` `first_paint`, `ghostty-vt` `paint`):
/// hc's exact prelude, rows ended by CR LF, the cursor last, then hc's end of the screen (`CSI ? 9001 l`) and its
/// status report. The recorded fixtures under `Fixtures/hc-paint` are paints captured from hc 0.1.16 itself.
final class HCPaintScreenTests: XCTestCase {
    private static let rule = String(repeating: "─", count: 60)

    /// One paint as hc writes it: hc's prelude, `prelude` (the modes the formatter restores first), the rows from
    /// the top, `trailer` (scroll region, ...), the cursor and `afterCursor`, the pen; then hc's end of the screen
    /// and a 7501 status report, and `tail` (what follows the paint: live output).
    static func paint(_ rows: [Int: String], cursor: (row: Int, column: Int), columns: Int = 80, rows count: Int = 24,
                      prelude: String = "", trailer: String = "", afterCursor: String = "",
                      tail: String = "") -> HCComposerPaint {
        var text = String(decoding: HCPaint.prelude, as: UTF8.self) + prelude
        var y = 0
        for row in rows.keys.sorted() {
            while y < row { text += "\r\n"; y += 1 }
            text += rows[row]! + "\u{1B}[0m"
        }
        text += trailer
        text += "\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H" + afterCursor + "\u{1B}[0m"
        text += "\u{1B}[?9001l\u{1B}]7501;state=idle\u{1B}\\" + tail
        return HCComposerPaint(bytes: Data(text.utf8), grid: HCGridSize(columns: UInt16(columns), rows: UInt16(count)))
    }

    static func faint(_ text: String) -> String { "\u{1B}[2m" + text + "\u{1B}[22m" }

    /// Claude Code's composer between its rules, at the bottom of a screen with some transcript above.
    /// Claude draws its prompt as `❯` and a no-break space.
    static let claudePrompt = "❯\u{00A0}"

    static func claude(_ composer: String, cursorColumn: Int = 2) -> HCComposerPaint {
        paint([2: "● Done. The tests pass.", 19: rule, 20: claudePrompt + composer, 21: rule, 22: "  ? for shortcuts"],
              cursor: (20, cursorColumn))
    }

    static func codex(_ composer: String, cursorColumn: Int = 2) -> HCComposerPaint {
        paint([2: "• Ran the build.", 20: "› " + composer, 22: "  100% context left"], cursor: (20, cursorColumn))
    }

    private func observe(_ paint: HCComposerPaint, _ harness: String) -> HCComposerObservation {
        HCComposerObservation.classify(paint, harness: harness)
    }

    // MARK: The states the screen path reads

    func testClaudesDimSuggestionIsASuggestionAndTheSameTextUprightIsADraft() {
        XCTAssertEqual(observe(Self.claude(Self.faint("Try \"fix the failing test\"")), "claude-code").state, .suggestion,
                       "SGR 2 is Claude's suggested prompt: empty for the doorbell (C11H-280)")
        let typed = observe(Self.claude("Try \"fix the failing test\"", cursorColumn: 29), "claude-code")
        XCTAssertEqual(typed.state, .draft, "the same text without SGR 2 is typed")
        XCTAssertEqual(typed.composer, "Try \"fix the failing test\"")
        XCTAssertEqual(observe(Self.claude(""), "claude-code").state, .empty)
    }

    func testCodexPlaceholderIsASuggestionAndTypedTextADraft() {
        XCTAssertEqual(observe(Self.codex(Self.faint("Ask Codex to do anything")), "codex").state, .suggestion)
        let draft = observe(Self.codex("half typed draft", cursorColumn: 18), "codex")
        XCTAssertEqual(draft.state, .draft)
        XCTAssertEqual(draft.composer, "half typed draft")
    }

    func testTheDoorbellLineInTheComposerReadsBackExactly() {
        let line = MailboxDoorbell.text
        let read = observe(Self.claude(line, cursorColumn: 2 + line.count), "claude-code")
        XCTAssertEqual(read.state, .draft)
        XCTAssertEqual(read.composer, line)
        XCTAssertTrue(MailboxHeadlessPrompt.admitsReturn(read))
        let extra = observe(Self.claude(line + " and more", cursorColumn: 2 + line.count + 9), "claude-code")
        XCTAssertFalse(MailboxHeadlessPrompt.admitsReturn(extra), "anything beside the line is not the line")
        XCTAssertFalse(MailboxHeadlessPrompt.admitsText(extra))
    }

    func testAClaudeChooserIsADialog() {
        let chooser = Screen(rows: [
            10: [("Do you want to proceed?", false)],
            11: [("❯ 1. Yes", false)],
            12: [("  2. Yes, and don't ask again this session", false)],
            13: [("  3. No, and tell Claude what to do differently (esc)", false)],
        ], cursor: (11, 0))
        XCTAssertEqual(observe(chooser.paint, "claude-code").state,
                       PromptInputClassifier.classify(chooser.nativeRegion, harness: "claude-code").state)
    }

    // MARK: The replay

    func testTheFinalCursorPositionIsTheScreensCursor() throws {
        let screen = try XCTUnwrap(HCPaintScreen.replay(Self.claude("", cursorColumn: 2).bytes, columns: 80, rows: 24))
        XCTAssertTrue(screen.isComplete)
        XCTAssertEqual(screen.cursorX, 2)
        XCTAssertEqual(screen.cursorY, 20)
        XCTAssertFalse(screen.pendingWrap)
        XCTAssertEqual(screen.text(row: 20).prefix(2), "❯\u{00A0}")
    }

    /// Ghostty restores a pending wrap by moving to the edge and printing the edge cell again.
    func testAPendingWrapIsRestoredFromTheReprintedEdgeCell() throws {
        let full = String(repeating: "x", count: 80)
        let paint = Self.paint([5: full], cursor: (5, 79), afterCursor: "\u{1B}[6;80Hx")
        let screen = try XCTUnwrap(HCPaintScreen.replay(paint.bytes, columns: 80, rows: 24))
        XCTAssertTrue(screen.isComplete)
        XCTAssertEqual(screen.cursorX, 79)
        XCTAssertTrue(screen.pendingWrap)
    }

    /// In origin mode the paint writes the cursor relative to the scroll region it restored just before.
    func testOriginModeCountsTheCursorFromTheScrollRegion() throws {
        let paint = Self.paint([20: "❯ "], cursor: (0, 2), prelude: "\u{1B}[?6h", trailer: "\u{1B}[3;22r")
        // The cursor line above is written with origin mode on, so row 1 of the region is screen row 3.
        let screen = try XCTUnwrap(HCPaintScreen.replay(paint.bytes, columns: 80, rows: 24))
        XCTAssertTrue(screen.isComplete)
        XCTAssertEqual(screen.cursorY, 2)
        XCTAssertEqual(screen.cursorX, 2)
    }

    /// The paint restores modes before the rows, so a program's insert mode is on while they print.
    func testInsertModeRestoredBeforeTheRowsLeavesTheSameCells() throws {
        let screen = try XCTUnwrap(HCPaintScreen.replay(
            Self.paint([20: "❯ " + Self.faint("Try it")], cursor: (20, 2), prelude: "\u{1B}[4h").bytes, columns: 80, rows: 24))
        XCTAssertTrue(screen.isComplete)
        XCTAssertTrue(screen.text(row: 20).hasPrefix("❯ Try it"))
        XCTAssertTrue(screen.cells(row: 20)[2].faint)
    }

    func testAWideCharacterTakesTwoCellsAndItsSpacerHasNoText() throws {
        let screen = try XCTUnwrap(HCPaintScreen.replay(
            Self.paint([20: Self.claudePrompt + "日本語 ok"], cursor: (20, 11)).bytes, columns: 80, rows: 24))
        XCTAssertTrue(screen.isComplete)
        let cells = screen.cells(row: 20)
        XCTAssertEqual(cells[2].text, "日")
        XCTAssertEqual(cells[3].text, "")
        XCTAssertEqual(cells[8].text, " ")
        XCTAssertEqual(cells[9].text, "o")
        let read = observe(Self.paint([19: Self.rule, 20: Self.claudePrompt + "日本語 ok", 21: Self.rule], cursor: (20, 11)),
                           "claude-code")
        XCTAssertEqual(read.state, .draft)
        XCTAssertEqual(read.composer, "日本語 ok")
    }

    func testTruecolorAndItalicReachTheCells() throws {
        let screen = try XCTUnwrap(HCPaintScreen.replay(
            Self.paint([20: "\u{1B}[3;38;2;110;110;110mBuild anything\u{1B}[23;39m done"], cursor: (20, 0)).bytes,
            columns: 80, rows: 24))
        let cells = screen.cells(row: 20)
        XCTAssertTrue(cells[0].italic)
        XCTAssertEqual(cells[0].fg, 0x6E6E6E)
        XCTAssertFalse(cells[15].italic)
        XCTAssertNil(cells[15].fg)
        let colon = try XCTUnwrap(HCPaintScreen.replay(
            Self.paint([1: "\u{1B}[38:2::1:2:3mX"], cursor: (1, 1)).bytes, columns: 80, rows: 24))
        XCTAssertEqual(colon.cells(row: 1)[0].fg, 0x010203)
    }

    // MARK: Failing closed

    private func recorded(_ name: String) throws -> HCComposerPaint {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/hc-paint/\(name)")
        return HCComposerPaint(bytes: try Data(contentsOf: url), grid: HCGridSize(columns: 80, rows: 24))
    }

    /// Repair 1, Astra's probe: the recorded Codex draft cut off right after its prompt. Before, the replay judged
    /// it a complete empty composer. A paint is judged only once hc's end of the screen has arrived.
    func testAPaintCutShortHolds() throws {
        let draft = try recorded("codex-draft.vt")
        let promptEnd = try XCTUnwrap(draft.bytes.range(of: Data("› ".utf8)))
        let cut = HCComposerPaint(bytes: draft.bytes[..<promptEnd.upperBound], grid: draft.grid)
        let read = observe(cut, "codex")
        XCTAssertEqual(read.state, .unknown)
        XCTAssertEqual(read.why, "paint_unterminated")
        XCTAssertEqual(observe(draft, "codex").state, .draft, "the whole paint is the draft")
    }

    /// Repair 1, Astra's probe: a private mode Ghostty's formatter never writes (`CSI ? 9999 h`) is not hc's paint.
    func testAnUnknownPrivateModeHolds() throws {
        let empty = try recorded("codex-empty.vt")
        let end = try XCTUnwrap(empty.bytes.range(of: Data("\u{1B}[?9001".utf8)))
        var bytes = Data(empty.bytes[..<end.lowerBound])
        bytes.append(Data("\u{1B}[?9999h".utf8))
        bytes.append(empty.bytes[end.lowerBound...])
        let read = observe(HCComposerPaint(bytes: bytes, grid: empty.grid), "codex")
        XCTAssertEqual(read.state, .unknown)
        XCTAssertEqual(read.why, "paint_private_mode")
        XCTAssertEqual(observe(empty, "codex").state, .empty)
    }

    /// Repair 1b: sequences that would save or restore the cursor or modes (1048, XTSAVE, XTRESTORE) hold.
    func testCursorAndModeSaveAndRestoreHold() {
        for (sequence, why) in [("\u{1B}[?1048h", "paint_private_mode"), ("\u{1B}[?1048l", "paint_private_mode"),
                                ("\u{1B}[?1049s", "paint_csi_?s"), ("\u{1B}[?1049r", "paint_csi_?r")] {
            let read = observe(Self.paint([19: Self.rule, 20: Self.claudePrompt, 21: Self.rule], cursor: (20, 2),
                                          afterCursor: sequence), "claude-code")
            XCTAssertEqual(read.state, .unknown, sequence.debugDescription)
            XCTAssertEqual(read.why, why, sequence.debugDescription)
        }
    }

    func testAPaintThatIsNotHCsHolds() {
        var bytes = Self.codex("half typed", cursorColumn: 12).bytes
        bytes[bytes.startIndex + 2] = UInt8(ascii: "?")  // another reset than hc 0.1.16's
        XCTAssertEqual(observe(HCComposerPaint(bytes: bytes, grid: HCGridSize(columns: 80, rows: 24)), "codex").why,
                       "paint_unrecognized")
    }

    /// What follows hc's end of the screen (its status reports, then live output) is not part of the screen read.
    func testOutputAfterThePaintIsNotReplayed() {
        let plain = Self.codex(Self.faint("Ask Codex to do anything"))
        let followed = Self.codex(Self.faint("Ask Codex to do anything"))
        var bytes = followed.bytes
        bytes.append(Data("\u{1B}[21;3Htyped later\u{1B}[3".utf8))
        XCTAssertEqual(observe(plain, "codex").state, .suggestion)
        XCTAssertEqual(observe(HCComposerPaint(bytes: bytes, grid: followed.grid), "codex").state, .suggestion)
    }

    func testASequenceTheFormatterNeverWritesHolds() {
        // DECFRA fills a rectangle; a paint never carries it.
        let read = observe(Self.paint([19: Self.rule, 20: Self.claudePrompt, 21: Self.rule], cursor: (20, 2),
                                      afterCursor: "\u{1B}[65;1;1;5;5$x"), "claude-code")
        XCTAssertEqual(read.state, .unknown)
        XCTAssertEqual(read.why, "paint_csi_$x")
        let erase = observe(Self.paint([19: Self.rule, 20: Self.claudePrompt, 21: Self.rule], cursor: (20, 2),
                                       afterCursor: "\u{1B}[K"), "claude-code")
        XCTAssertEqual(erase.why, "paint_csi_K", "an erase is live output, not a paint")
    }

    /// The screen section ends inside a sequence: not a screen to judge.
    func testAScreenSectionThatEndsInsideASequenceHolds() {
        let read = observe(Self.paint([19: Self.rule, 20: Self.claudePrompt, 21: Self.rule], cursor: (20, 2),
                                      afterCursor: "\u{1B}[3"), "claude-code")
        XCTAssertEqual(read.state, .unknown)
    }

    func testAnOpenSynchronizedUpdateIsUnknown() {
        let read = observe(Self.paint([19: Self.rule, 20: Self.claudePrompt, 21: Self.rule], cursor: (20, 2),
                                      afterCursor: "\u{1B}[?2026h"), "claude-code")
        XCTAssertEqual(read.why, "paint_synchronized_update")
    }

    /// A paint never wraps: a row wider than the grid means the widths disagree, so nothing about it is trusted.
    func testAnAutowrapIsUnknown() {
        let wide = String(repeating: "y", count: 81)
        let read = observe(Self.paint([19: Self.rule, 20: Self.claudePrompt + wide, 21: Self.rule], cursor: (20, 2)), "claude-code")
        XCTAssertEqual(read.state, .unknown)
        XCTAssertEqual(read.why, "paint_autowrap")
    }

    func testAReadFailureIsUnavailableWithItsWhy() {
        let read = HCComposerObservation.from(.failure(.unterminated), harness: "claude-code")
        XCTAssertEqual(read.state, .unavailable)
        XCTAssertEqual(read.why, "paint_unterminated")
        XCTAssertNil(MailboxHeadlessPrompt.read(readiness: .ready, composer: read)?.prompt)
        XCTAssertEqual(MailboxHeadlessPrompt.read(readiness: .ready, composer: read)?.hold, "composer_unread")
    }

    // MARK: The native reader's windows

    func testTheCursorWindowIsNineRowsAboveAndSixBelowWithEveryColumn() throws {
        let screen = try XCTUnwrap(HCPaintScreen.replay(Self.claude("").bytes, columns: 80, rows: 24))
        let region = try XCTUnwrap(screen.region(.cursor))
        XCTAssertTrue(region.complete)
        XCTAssertEqual(region.rows.first?.screenY, 11)
        XCTAssertEqual(region.rows.last?.screenY, 23)
        XCTAssertTrue(region.rows.allSatisfy { $0.cellRange.count == 80 && !$0.softWrap && !$0.wrapContinuation })
        XCTAssertEqual(region.cursorX, 2)
        XCTAssertEqual(region.cursorY, 20)
    }

    /// C11H-280's wide panel: the cursor window passes the 4096-cell budget, the bottom window drops whole rows
    /// from its top and stays complete, and the screen path's choice of windows reads the composer from it.
    func testAWidePanelReadsItsComposerFromTheBottomWindow() throws {
        let paint = Self.paint([29: String(repeating: "─", count: 300), 30: Self.claudePrompt + Self.faint("Try it"),
                                31: String(repeating: "─", count: 300)],
                               cursor: (30, 2), columns: 300, rows: 40)
        let screen = try XCTUnwrap(HCPaintScreen.replay(paint.bytes, columns: 300, rows: 40))
        XCTAssertEqual(screen.region(.cursor)?.complete, false, "16 rows of 300 cells pass the 4096-cell budget")
        let bottom = try XCTUnwrap(screen.region(.bottom))
        XCTAssertTrue(bottom.complete)
        XCTAssertEqual(bottom.rows.last?.screenY, 39)
        XCTAssertTrue(bottom.rows.contains { $0.screenY == 30 }, "the kept rows hold the cursor's")
        XCTAssertLessThanOrEqual(bottom.cells.count, 4096)
        XCTAssertEqual(observe(paint, "claude-code").state, .suggestion)
    }

    // MARK: Parity with the screen path

    /// A screen described as rows of (text, faint) spans. `paint` is it as hc writes it; `nativeRegion` is what the
    /// native reader captures of it (the cursor window, every column, a blank as a space), built from the
    /// description alone, independently of `HCPaintScreen`. Narrow characters only.
    struct Screen {
        let rows: [Int: [(String, Bool)]]
        let cursor: (row: Int, column: Int)
        var columns = 80
        var rowCount = 24

        var paint: HCComposerPaint {
            HCPaintScreenTests.paint(rows.mapValues { spans in
                spans.map { $0.1 ? HCPaintScreenTests.faint($0.0) : $0.0 }.joined()
            }, cursor: cursor, columns: columns, rows: rowCount)
        }

        var nativeRegion: PromptRegionSnapshot {
            let first = cursor.row - min(cursor.row, 9)
            let last = min(rowCount - 1, cursor.row + 6)
            var text = Data()
            var cells: [PromptRegionCell] = []
            var regionRows: [PromptRegionRow] = []
            for y in first...last {
                var line: [(Unicode.Scalar, Bool)] = []
                for (span, faint) in rows[y] ?? [] { line += span.unicodeScalars.map { ($0, faint) } }
                let start = cells.count
                for x in 0..<columns {
                    let (scalar, faint): (Unicode.Scalar, Bool) = x < line.count ? line[x] : (" ", false)
                    let bytes = Data(String(scalar).utf8)
                    cells.append(PromptRegionCell(textOffset: text.count, textLength: bytes.count, faint: faint))
                    text.append(bytes)
                }
                regionRows.append(PromptRegionRow(screenY: y, cellRange: start..<cells.count, softWrap: false,
                                                  wrapContinuation: false))
            }
            return PromptRegionSnapshot(cursorX: cursor.column, cursorY: cursor.row, cursorPendingWrap: false,
                                        complete: true, rows: regionRows, cells: cells, text: text)
        }
    }

    /// The same screens rendered as hc paints them and replayed classify as their native regions do.
    func testReplayedScreensClassifyAsTheirNativeRegions() throws {
        let rule = [(Self.rule, false)]
        let cases: [(String, Screen)] = [
            ("claude-code", Screen(rows: [19: rule, 20: [(Self.claudePrompt, false)], 21: rule], cursor: (20, 2))),
            ("claude-code", Screen(rows: [19: rule, 20: [(Self.claudePrompt, false), ("Try \"refactor the parser\"", true)], 21: rule],
                                   cursor: (20, 2))),
            ("claude-code", Screen(rows: [19: rule, 20: [(Self.claudePrompt + "operator unfinished text", false)], 21: rule],
                                   cursor: (20, 26))),
            ("claude-code", Screen(rows: [19: rule, 20: [(Self.claudePrompt + "first line", false)], 21: [("  second line", false)],
                                          22: rule], cursor: (21, 13))),
            ("codex", Screen(rows: [20: [("› ", false), ("Ask Codex to do anything", true)]], cursor: (20, 2))),
            ("codex", Screen(rows: [20: [("› first line", false)], 21: [("  second line", false)]], cursor: (21, 13))),
            ("opencode", Screen(rows: [20: [("┃  ", false), ("Ask anything...", true)]], cursor: (20, 3))),
            ("pi", Screen(rows: [20: rule, 21: [("", false)], 22: rule], cursor: (21, 0))),
            ("omp", Screen(rows: [19: rule, 20: [(Self.claudePrompt + "draft for an untyped panel", false)], 21: rule], cursor: (20, 28))),
        ]
        var states: Set<PromptInputState> = []
        for (harness, screen) in cases {
            let replayed = observe(screen.paint, harness).state
            XCTAssertEqual(replayed, PromptInputClassifier.classify(screen.nativeRegion, harness: harness).state,
                           "\(harness): \(screen.rows)")
            states.insert(replayed)
        }
        XCTAssertTrue(states.isSuperset(of: [.empty, .suggestion, .draft]), "the cases cover what the doorbell decides: \(states)")
    }

    // MARK: Paints recorded from hc 0.1.16

    private struct RecordedPaint: Decodable {
        let file: String
        let harness: String
        let cols: Int
        let rows: Int
        let expect: String
        let draft_text: String?
        let note: String?
    }

    private struct Manifest: Decodable {
        let hc_version: String
        let hc_sha256: String
        let paints: [RecordedPaint]
    }

    private struct PinnedHC: Decodable {
        let version: String
        let sha256: String
    }

    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/hc-paint")
    }

    /// The recorded paints are hc 0.1.16's format. An hc pin bump must recapture them (`wave3-run/306/LAB.md`'s
    /// procedure) before this passes, so a changed paint format never rides on old fixtures.
    func testTheRecordedPaintsComeFromThePinnedHC() throws {
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: Self.fixtures.appendingPathComponent("manifest.json")))
        let pin = try JSONDecoder().decode(PinnedHC.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/hc/hc-source.json")))
        XCTAssertEqual(manifest.hc_version, pin.version, "recapture the hc paint fixtures for the new pin")
        XCTAssertEqual(manifest.hc_sha256, pin.sha256, "recapture the hc paint fixtures for the new pin")
    }

    func testRecordedHCPaintsClassifyAsTheTUIDrewThem() throws {
        let folder = Self.fixtures
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: folder.appendingPathComponent("manifest.json"))).paints
        XCTAssertFalse(manifest.isEmpty)
        for entry in manifest {
            let bytes = try Data(contentsOf: folder.appendingPathComponent(entry.file))
            let read = HCComposerObservation.classify(
                HCComposerPaint(bytes: bytes, grid: HCGridSize(columns: UInt16(entry.cols), rows: UInt16(entry.rows))), harness: entry.harness)
            XCTAssertEqual(read.state.rawValue, entry.expect, "\(entry.file): \(entry.note ?? "") why=\(read.why ?? "-")")
            if let text = entry.draft_text {
                // A wrapped draft comes back as rows (the paint carries no soft wrap): the same words, which is
                // what the doorbell's comparison checks (`FeedAnswerComposerCheck`).
                let words = { (value: String?) in value?.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                XCTAssertEqual(words(read.composer), words(text), entry.file)
            }
        }
    }
}
