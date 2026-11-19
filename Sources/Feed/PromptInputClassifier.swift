import Foundation

enum PromptInputState: String, Equatable, Sendable {
    case empty
    case suggestion
    case draft
    case dialog
    case unknown
    case unavailable
}

/// Which Claude chooser is up. Only `PromptInputClassifier.chooserKind` reports
/// it; the classification stays `.dialog` and its `dialogKind` (the supervisor's
/// permission and choice labels) is untouched.
enum PromptChooserKind: String, Equatable, Sendable {
    /// Claude Code's folder-trust check. Its highlighted option is `No, exit`.
    case trust
    /// Claude Code's "make this plan?" chooser.
    case plan
    /// Claude Code's `Resume this conversation?` dialog after a long-idle
    /// session is resumed (C11H-320).
    case resume
    /// Claude Code's rate-limit options menu, `What do you want to do?`
    /// under `You've hit your … limit` (C11H-320).
    case usageLimit = "usage_limit"
}

struct PromptInputClassification: Equatable, Sendable {
    let state: PromptInputState
    let draftLength: Int?
    var dialogKind: String? = nil

    static let unknown = Self(state: .unknown, draftLength: nil)

    func responseFields(source: String?, observedAtMs: Int64?, chooser: PromptChooserKind? = nil) -> [String: Any] {
        [
            "input_state": state.rawValue,
            "draft_length": draftLength.map { $0 as Any } ?? NSNull(),
            "dialog_kind": publicDialogKind(chooser: chooser).map { $0 as Any } ?? NSNull(),
            "source": source.map { $0 as Any } ?? NSNull(),
            "observed_at_ms": observedAtMs.map { $0 as Any } ?? NSNull(),
        ]
    }

    /// The dialog's name as `input-state` and `fleet` print it (C11H-320):
    /// `permission`, `choice`, `trust`, `plan`, `resume`, `usage_limit`, or
    /// null when the state is not `dialog` or the dialog is not recognized.
    func publicDialogKind(chooser: PromptChooserKind? = nil) -> String? {
        guard state == .dialog else { return nil }
        return dialogKind ?? chooser?.rawValue
    }
}

struct PromptInputObservation: Sendable {
    let classification: PromptInputClassification
    let source: String?
    let observedAtMs: Int64?

    static let unknown = Self(classification: .unknown, source: nil, observedAtMs: nil)
    static let unavailable = Self(
        classification: PromptInputClassification(state: .unavailable, draftLength: nil),
        source: nil,
        observedAtMs: nil
    )

    /// Which chooser a `dialog` is when the classification carries no kind.
    var chooser: PromptChooserKind? = nil

    static func activeScreen(_ region: PromptRegionSnapshot, harness: String?) -> Self {
        let classification = PromptInputClassifier.classify(region, harness: harness)
        return Self(
            classification: classification,
            source: "active_screen",
            observedAtMs: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
            chooser: classification.state == .dialog && classification.dialogKind == nil
                ? PromptInputClassifier.chooserKind(region, harness: harness) : nil
        )
    }

    var responseFields: [String: Any] {
        classification.responseFields(source: source, observedAtMs: observedAtMs, chooser: chooser)
    }
}

struct PromptRegionCell: Equatable, Sendable {
    let textOffset: Int
    let textLength: Int
    let faint: Bool
    /// SGR 3. Grok draws its next-prompt suggestion italic, not faint. A
    /// capture without it reads as plain, so the suggestion stays a draft.
    var italic: Bool = false
    /// Explicit truecolor foreground and background as 0xRRGGBB. Nil for a
    /// palette or default color. Grok's unfocused placeholder differs from
    /// typed text only here, so a cell without both reads as typed.
    var fg: UInt32? = nil
    var bg: UInt32? = nil
}

struct PromptRegionRow: Equatable, Sendable {
    let screenY: Int
    let cellRange: Range<Int>
    let softWrap: Bool
    let wrapContinuation: Bool
}

struct PromptRegionSnapshot: Equatable, Sendable {
    let cursorX: Int
    let cursorY: Int
    let cursorPendingWrap: Bool
    let complete: Bool
    let rows: [PromptRegionRow]
    let cells: [PromptRegionCell]
    let text: Data
    /// The last rows of the screen, read only for a harness whose composer is
    /// pinned to the bottom (Grok and Pi choosers). Nil when not read or the read was busy.
    var screenBottom: PromptRegionRows? = nil
    /// Whether rows carry the terminal's soft-wrap flags. A surface's do; hc's
    /// paint (C11H-306) has none, so there a full-width row may be a wrap.
    var wrapFlags: Bool = true
}

/// A bounded window of screen rows without its own cursor.
struct PromptRegionRows: Equatable, Sendable {
    let complete: Bool
    let rows: [PromptRegionRow]
    let cells: [PromptRegionCell]
    let text: Data
    /// As `PromptRegionSnapshot.wrapFlags`.
    var wrapFlags: Bool = true
}

enum PromptInputClassifier {
    static let maxRows = 16
    static let maxCells = 4096
    static let maxTextBytes = 16 * 1024

    private struct StyledScalar {
        let value: Unicode.Scalar
        let faint: Bool
        var italic: Bool = false
        var fg: UInt32? = nil
        var bg: UInt32? = nil
    }

    private struct Line {
        let y: Int
        let softWrap: Bool
        let wrapContinuation: Bool
        var scalars: [StyledScalar]

        var text: String {
            String(String.UnicodeScalarView(scalars.map(\.value)))
        }
    }

    private struct PromptPrefix {
        let endIndex: Int
        let isBoxed: Bool
        let isCodex: Bool
    }

    private struct Analysis {
        let classification: PromptInputClassification
        let composerText: String?
    }

    /// A composer shape is read only for the harness that owns it. `harness`
    /// is the panel's `terminal_type` (`claude-code`, `codex`, `grok`,
    /// `opencode`, `pi`). Anything else, including omp and GitHub Copilot,
    /// runs the unboxed prefix reader only to refuse a draft or a dialog.
    /// Empty and suggestion on those panels stay unknown, so they are not rung.
    static func classify(_ region: PromptRegionSnapshot, harness: String?, forSupervisor: Bool = false) -> PromptInputClassification {
        analyze(region, harness: harness, forSupervisor: forSupervisor).classification
    }

    /// Transiently returns the typed text for an exact composer comparison.
    /// Suggestions, dialogs, incomplete captures, and unsupported layouts do
    /// not expose text to callers.
    static func composerText(_ region: PromptRegionSnapshot, harness: String?) -> String? {
        let analysis = analyze(region, harness: harness)
        guard analysis.classification.state == .draft else { return nil }
        return analysis.composerText
    }

    private enum ComposerReader: Equatable {
        case prefix
        case grok
        case openCode
        case pi
    }

    /// Grok keeps its composer at the bottom of the screen and, unfocused,
    /// parks its hidden cursor anywhere. Its panels also read the bottom rows.
    /// Pi's extra chooser context is supervisor-only; send and doorbell reads
    /// retain their cursor-based composer path.
    static func readsScreenBottom(harness: String?, forSupervisor: Bool = false) -> Bool {
        composerReader(for: harness) == .grok || (forSupervisor && composerReader(for: harness) == .pi)
    }

    /// C11H-280: Claude Code, Codex, OpenCode and Pi pin their composer near
    /// the bottom of the screen, and the cursor window (16 rows of every
    /// column) passes the native 4096-cell budget once a panel is wider than
    /// about 315 columns. That read comes back incomplete, so a wide panel's
    /// box was always `unknown`: the doorbell held mail and `send` could not
    /// check it. The bottom window drops whole rows from its top instead and
    /// stays complete. Read it only after a clipped cursor read, so narrow
    /// panels read once. Grok reads the bottom window already, with its own
    /// rules for a parked cursor, and keeps them.
    static func readsScreenBottom(harness: String?, afterCursorRead cursor: PromptRegionSnapshot) -> Bool {
        guard !cursor.complete else { return false }
        switch composerReader(for: harness) {
        case .prefix, .openCode, .pi:
            return true
        case .grok, nil:
            return false
        }
    }

    /// C11H-320: Claude Code's resume dialog, rate-limit menu and
    /// auto-continue wait hide the cursor, so the cursor window of a narrow
    /// panel can miss them. A Claude panel always reads the bottom rows too,
    /// where those are drawn: one more bounded native copy, and nothing is
    /// classified on main to decide it.
    static func readsClaudeDialogBottom(harness: String?) -> Bool {
        isClaude(harness)
    }

    /// The window a clipped cursor read is classified from: the bottom rows,
    /// when that read is complete. Nil keeps the cursor read, which an
    /// incomplete capture leaves `unknown`. A bottom window without the cursor
    /// row is `unknown` too: the analysis needs the cursor's row.
    private static func bottomWindow(for region: PromptRegionSnapshot, harness: String?) -> PromptRegionSnapshot? {
        guard readsScreenBottom(harness: harness, afterCursorRead: region),
              let bottom = region.screenBottom, bottom.complete else { return nil }
        return PromptRegionSnapshot(
            cursorX: region.cursorX,
            cursorY: region.cursorY,
            cursorPendingWrap: region.cursorPendingWrap,
            complete: true,
            rows: bottom.rows,
            cells: bottom.cells,
            text: bottom.text,
            screenBottom: bottom,
            wrapFlags: bottom.wrapFlags
        )
    }

    static func supportsComposer(harness: String?) -> Bool {
        composerReader(for: harness) != nil
    }

    private static func composerReader(for harness: String?) -> ComposerReader? {
        switch harness?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude-code", "codex":
            return .prefix
        case "grok":
            return .grok
        case "opencode":
            return .openCode
        case "pi":
            return .pi
        default:
            return nil
        }
    }

    private static func analyze(_ captured: PromptRegionSnapshot, harness: String?, forSupervisor: Bool = false) -> Analysis {
        // Claude Code draws its resume dialog and its rate-limit menu at the
        // bottom of the screen with the cursor hidden, so they are read from
        // the bottom window alone, before any cursor-anchored reader.
        if isClaude(harness), let bottom = captured.screenBottom, let kind = claudeBlockingDialog(bottom) {
            return Analysis(classification: .init(state: .dialog, draftLength: nil, dialogKind: kind.rawValue), composerText: nil)
        }
        let region = bottomWindow(for: captured, harness: harness) ?? captured
        guard region.complete,
              !region.rows.isEmpty,
              region.rows.count <= maxRows,
              region.cells.count <= maxCells,
              region.text.count <= maxTextBytes else {
            return Analysis(classification: .unknown, composerText: nil)
        }

        let bytes = Array(region.text)
        guard let lines = makeLines(region, bytes: bytes),
              let cursorIndex = lines.firstIndex(where: { $0.y == region.cursorY }) else {
            return Analysis(classification: .unknown, composerText: nil)
        }
        guard region.cursorX >= 0,
              region.cursorX <= region.rows[cursorIndex].cellRange.count else {
            return Analysis(classification: .unknown, composerText: nil)
        }

        if let kind = supervisorDialog(lines, harness: harness, cursorY: region.cursorY, forSupervisor: forSupervisor) {
            return Analysis(classification: .init(state: .dialog, draftLength: nil, dialogKind: kind), composerText: nil)
        }
        // Pi's extension chooser hides the cursor. Read its bounded bottom
        // rows as well, but require the chooser footer and bottom status rails.
        if forSupervisor, composerReader(for: harness) == .pi, let bottom = region.screenBottom,
           bottom.complete, bottom.rows.count <= maxRows, bottom.cells.count <= maxCells,
           bottom.text.count <= maxTextBytes,
           let bottomLines = makeLines(rows: bottom.rows, cells: bottom.cells, bytes: Array(bottom.text)),
           piChoice(bottomLines) {
            return Analysis(classification: .init(state: .dialog, draftLength: nil, dialogKind: "choice"), composerText: nil)
        }

        let unknown = Analysis(classification: .unknown, composerText: nil)
        switch composerReader(for: harness) {
        case .openCode:
            return openCodeComposer(lines, cursorIndex: cursorIndex, cursorX: region.cursorX) ?? unknown
        case .pi:
            return piComposer(lines, cursorIndex: cursorIndex) ?? unknown
        case .grok:
            if let unfocused = grokUnfocusedComposer(
                lines,
                cursorY: region.cursorY,
                screenBottom: region.screenBottom
            ) {
                return unfocused
            }
            return prefixComposer(
                lines,
                cursorIndex: cursorIndex,
                cursorX: region.cursorX,
                cursorY: region.cursorY,
                boxed: true,
                italicSuggestion: true
            )
        case .prefix:
            return prefixComposer(
                lines,
                cursorIndex: cursorIndex,
                cursorX: region.cursorX,
                cursorY: region.cursorY,
                boxed: false
            )
        case nil:
            // Refusal only. `c11 send` still refuses a Claude-style draft or
            // dialog on an untyped panel. Empty and suggestion stay unknown,
            // so the doorbell does not admit the panel.
            let window = isShell(harness)
                ? cursorLogicalLine(lines, cursorIndex: cursorIndex)
                : (lines: lines, cursorIndex: cursorIndex)
            let scanned = prefixComposer(
                window.lines,
                cursorIndex: window.cursorIndex,
                cursorX: region.cursorX,
                cursorY: region.cursorY,
                boxed: false
            )
            switch scanned.classification.state {
            case .draft, .dialog:
                return scanned
            case .empty, .suggestion, .unknown, .unavailable:
                return unknown
            }
        }
    }

    /// Claude Code and Codex share the unboxed `❯` / `›` reader, including
    /// Claude's chooser. Grok's reader is only the boxed `│ ❯` composer.
    /// Neither falls through to another harness's shape.
    ///
    /// `italicSuggestion` is Grok's next-prompt ghost text: SGR 3 italic in a
    /// grey, never SGR 2, with the cursor parked on its first cell. Grok
    /// draws typed text, pastes, slash completions and mentions upright
    /// (Grok 1.0.50, Grok 4.7). Italic reads as a suggestion only when every
    /// visible character in the composer is italic, the first content cell is
    /// an italic glyph, and the cursor sits on it; anything else is typed
    /// text, so a draft is never typed into. The one shape these cells cannot
    /// separate is an all-italic typed draft with the cursor moved home; the
    /// rule rests on Grok never drawing typed text italic, and the captured
    /// fixtures in `GrokPromptSuggestionTests` pin that.
    private static func prefixComposer(
        _ lines: [Line],
        cursorIndex: Int,
        cursorX: Int,
        cursorY: Int,
        boxed: Bool,
        italicSuggestion: Bool = false
    ) -> Analysis {
        if !boxed {
            if isSupportedDialog(lines, cursorY: cursorY) {
                return Analysis(
                    classification: PromptInputClassification(state: .dialog, draftLength: nil),
                    composerText: nil
                )
            }
            if isEmptyCodexPrompt(lines[cursorIndex], cursorX: cursorX) {
                return Analysis(
                    classification: PromptInputClassification(state: .suggestion, draftLength: nil),
                    composerText: nil
                )
            }
        }

        guard let promptIndex = lines.indices.reversed().first(where: { index in
            lines[index].y <= cursorY && acceptedPrefix(in: lines[index], boxed: boxed) != nil
        }), promptIndex <= cursorIndex,
              let prefix = acceptedPrefix(in: lines[promptIndex], boxed: boxed) else {
            return Analysis(classification: .unknown, composerText: nil)
        }

        var typedScalars: [Unicode.Scalar] = []
        var hasTypedText = false
        var hasFaintSuggestion = false
        var hasUprightText = false
        var firstContentIsItalic = false
        var previousIndex = promptIndex
        var stoppedAtRule = false

        for index in promptIndex..<lines.count {
            let line = lines[index]
            if index > promptIndex {
                let previous = lines[previousIndex]
                if line.y != previous.y + 1 || previous.softWrap != line.wrapContinuation {
                    return Analysis(classification: .unknown, composerText: nil)
                }
                if isRule(line) || (line.y > cursorY && isClosingBoxEdge(line)) {
                    // The composer's closing rule sits below the cursor row. A rule
                    // above it means the typed row was never reached: not empty.
                    if line.y <= cursorY {
                        return Analysis(classification: .unknown, composerText: nil)
                    }
                    stoppedAtRule = true
                    break
                }
                // Blank rows inside a multiline composer (leading or embedded) are
                // content; only a blank row past the cursor row ends the scan.
                if isBlank(line), line.y > cursorY, !previous.softWrap {
                    stoppedAtRule = true
                    break
                }
                if !previous.softWrap {
                    typedScalars.append("\n")
                }
            }

            var content = line.scalars
            if index == promptIndex {
                content = Array(content.dropFirst(prefix.endIndex))
            } else if prefix.isBoxed {
                content = stripLeadingBoxEdge(content)
            } else if prefix.isCodex {
                content = stripCodexContinuationIndent(content)
            }
            if prefix.isBoxed {
                content = stripTrailingBoxEdge(content)
            }

            // Rows are padded to the pane width; the padding is not typed text,
            // so a hard row's trailing whitespace is dropped (a soft-wrapped row's
            // trailing space is real content).
            var rowScalars: [Unicode.Scalar] = []
            for (offset, item) in content.enumerated() {
                if index == promptIndex, offset == 0 {
                    firstContentIsItalic = item.italic && !item.faint && !isWhitespace(item.value)
                }
                guard !item.faint else {
                    if !isWhitespace(item.value) { hasFaintSuggestion = true }
                    continue
                }
                rowScalars.append(item.value)
                if !isWhitespace(item.value) {
                    hasTypedText = true
                    if !item.italic { hasUprightText = true }
                }
            }
            if !line.softWrap {
                while let last = rowScalars.last, isWhitespace(last) { rowScalars.removeLast() }
            }
            typedScalars.append(contentsOf: rowScalars)
            previousIndex = index
        }

        // If the bounded window ends halfway through a soft-wrapped line, the
        // composer may continue outside the capture and cannot be called empty.
        if !stoppedAtRule, let last = lines.last, last.softWrap {
            return Analysis(classification: .unknown, composerText: nil)
        }

        guard hasTypedText else {
            return Analysis(
                classification: PromptInputClassification(
                    state: hasFaintSuggestion ? .suggestion : .empty,
                    draftLength: nil
                ),
                composerText: ""
            )
        }

        // `prefix.endIndex` is a scalar index, and here also the cell column:
        // every cell of Grok's `│ ❯ ` prefix is one narrow, single-scalar cell.
        if italicSuggestion,
           !hasUprightText,
           firstContentIsItalic,
           cursorY == lines[promptIndex].y,
           cursorX == prefix.endIndex {
            return Analysis(
                classification: PromptInputClassification(state: .suggestion, draftLength: nil),
                composerText: ""
            )
        }

        let trimmed = trimWhitespace(typedScalars)
        return Analysis(
            classification: PromptInputClassification(state: .draft, draftLength: trimmed.count),
            composerText: String(String.UnicodeScalarView(typedScalars))
        )
    }

    /// Grok's composer while Grok's own focus is elsewhere, after a click in
    /// its transcript. Grok draws the box dim, hides the cursor and parks it
    /// outside the box: on the footer, or far above after a hover. A paste
    /// still lands in the composer and refocuses it, so its dim `Build
    /// anything` placeholder is a suggestion. A typed draft that lost focus
    /// has the same text, faint and italic bits; only its brighter grey
    /// differs, and a paste would splice onto it. So each visible character
    /// must be low-contrast against its own background to count as ghost
    /// text. A character without both colors counts as typed. Grok draws no
    /// SGR 2 here, so faint is not a signal on this path.
    ///
    /// Nil when the cursor is inside the box or no whole composer is visible
    /// in the cursor window or the screen's bottom rows: the focused reader
    /// decides.
    private static func grokUnfocusedComposer(
        _ lines: [Line],
        cursorY: Int,
        screenBottom: PromptRegionRows?
    ) -> Analysis? {
        if let box = grokComposerBox(lines) {
            return box.holds(cursorY) ? nil : unfocusedGrokComposer(lines, box: box)
        }
        guard let screenBottom, screenBottom.complete,
              screenBottom.rows.count <= maxRows,
              screenBottom.cells.count <= maxCells,
              screenBottom.text.count <= maxTextBytes,
              let bottomLines = makeLines(
                rows: screenBottom.rows,
                cells: screenBottom.cells,
                bytes: Array(screenBottom.text)
              ),
              let box = grokComposerBox(bottomLines) else { return nil }
        return box.holds(cursorY) ? nil : unfocusedGrokComposer(bottomLines, box: box)
    }

    private struct GrokComposerBox {
        let promptIndex: Int
        let closingIndex: Int
        let prefix: PromptPrefix
        let promptY: Int
        let closingY: Int

        /// The cursor sits on the prompt row or a row of the composer below it.
        func holds(_ cursorY: Int) -> Bool {
            promptY <= cursorY && cursorY < closingY
        }
    }

    /// The lowest whole composer: a rounded `╭` top edge, the `│ ❯` prompt
    /// row, any `│` continuation rows, and a rounded `╰` closing edge, on
    /// consecutive rows. Grok's transcript hover box uses square corners and
    /// is not a composer.
    private static func grokComposerBox(_ lines: [Line]) -> GrokComposerBox? {
        for closing in lines.indices.reversed() where firstGlyph(lines[closing]) == 0x2570 {
            var index = closing - 1
            while index > 0, lines[index].y + 1 == lines[index + 1].y {
                if let prefix = acceptedPrefix(in: lines[index], boxed: true) {
                    guard lines[index - 1].y + 1 == lines[index].y,
                          firstGlyph(lines[index - 1]) == 0x256D else { break }
                    return GrokComposerBox(
                        promptIndex: index,
                        closingIndex: closing,
                        prefix: prefix,
                        promptY: lines[index].y,
                        closingY: lines[closing].y
                    )
                }
                guard firstGlyph(lines[index]) == 0x2502 else { break }
                index -= 1
            }
        }
        return nil
    }

    private static func unfocusedGrokComposer(_ lines: [Line], box: GrokComposerBox) -> Analysis {
        var typedScalars: [Unicode.Scalar] = []
        var hasTyped = false
        var hasGhost = false
        for index in box.promptIndex..<box.closingIndex {
            let line = lines[index]
            if index > box.promptIndex, !lines[index - 1].softWrap {
                typedScalars.append("\n")
            }
            var content = index == box.promptIndex
                ? Array(line.scalars.dropFirst(box.prefix.endIndex))
                : stripLeadingBoxEdge(line.scalars)
            content = stripTrailingBoxEdge(content)
            var rowScalars: [Unicode.Scalar] = []
            for item in content {
                if !isWhitespace(item.value) {
                    if isGhostText(item) {
                        hasGhost = true
                    } else {
                        hasTyped = true
                    }
                }
                rowScalars.append(item.value)
            }
            if !line.softWrap {
                while let last = rowScalars.last, isWhitespace(last) { rowScalars.removeLast() }
            }
            typedScalars.append(contentsOf: rowScalars)
        }
        guard hasTyped else {
            return Analysis(
                classification: PromptInputClassification(
                    state: hasGhost ? .suggestion : .empty,
                    draftLength: nil
                ),
                composerText: ""
            )
        }
        let trimmed = trimWhitespace(typedScalars)
        return Analysis(
            classification: PromptInputClassification(state: .draft, draftLength: trimmed.count),
            composerText: String(String.UnicodeScalarView(typedScalars))
        )
    }

    /// Below this contrast against its own background, a character is a hint,
    /// not text: WCAG's 3:1 floor for legible UI text. Grok 1.0.52 on its
    /// own background: placeholder 2.2:1, italic suggestion 2.6:1, an
    /// unfocused typed draft 6.6:1, a focused one 14:1.
    static let ghostTextContrast = 3.0

    private static func isGhostText(_ item: StyledScalar) -> Bool {
        guard let fg = item.fg, let bg = item.bg else { return false }
        return contrastRatio(fg, bg) < ghostTextContrast
    }

    /// WCAG 2 contrast ratio of two 0xRRGGBB colors.
    static func contrastRatio(_ first: UInt32, _ second: UInt32) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((rgb >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private static func firstGlyph(_ line: Line) -> UInt32? {
        line.scalars.map(\.value.value).first(where: { !isWhitespaceValue($0) })
    }

    private static func makeLines(_ region: PromptRegionSnapshot, bytes: [UInt8]) -> [Line]? {
        makeLines(rows: region.rows, cells: region.cells, bytes: bytes)
    }

    private static func makeLines(rows: [PromptRegionRow], cells: [PromptRegionCell], bytes: [UInt8]) -> [Line]? {
        var result: [Line] = []
        result.reserveCapacity(rows.count)

        for row in rows {
            guard row.cellRange.lowerBound >= 0,
                  row.cellRange.upperBound <= cells.count else { return nil }
            var scalars: [StyledScalar] = []
            for cell in cells[row.cellRange] {
                guard cell.textOffset >= 0, cell.textLength >= 0,
                      cell.textOffset <= bytes.count,
                      cell.textLength <= bytes.count - cell.textOffset else { return nil }
                guard cell.textLength > 0 else { continue }
                let start = cell.textOffset
                let end = start + cell.textLength
                let text = String(decoding: bytes[start..<end], as: UTF8.self)
                for scalar in text.unicodeScalars {
                    scalars.append(StyledScalar(
                        value: scalar,
                        faint: cell.faint,
                        italic: cell.italic,
                        fg: cell.fg,
                        bg: cell.bg
                    ))
                }
            }
            result.append(Line(
                y: row.screenY,
                softWrap: row.softWrap,
                wrapContinuation: row.wrapContinuation,
                scalars: scalars
            ))
        }
        return result
    }

    private static func currentPromptPrefix(in line: Line) -> PromptPrefix? {
        var index = 0
        while index < line.scalars.count, line.scalars[index].value == " " { index += 1 }
        var boxed = false
        if index < line.scalars.count, line.scalars[index].value.value == 0x2502 {
            boxed = true
            index += 1
            while index < line.scalars.count, line.scalars[index].value == " " { index += 1 }
        }
        if index + 1 < line.scalars.count,
           line.scalars[index].value.value == 0x203A,
           line.scalars[index + 1].value == " ",
           !line.scalars[index].faint, !line.scalars[index + 1].faint {
            return PromptPrefix(endIndex: index + 2, isBoxed: false, isCodex: true)
        }
        guard index + 1 < line.scalars.count,
              line.scalars[index].value.value == 0x276F,
              !line.scalars[index].faint,
              !line.scalars[index + 1].faint else { return nil }
        let gap = line.scalars[index + 1].value
        // Claude's live composer uses a non-breaking space. A historical
        // `❯ ` row and a dialog option use a normal space and stay unknown
        // unless they sit inside a box, which is Grok's composer.
        guard gap.value == 0x00A0 || (boxed && gap == " ") else { return nil }
        return PromptPrefix(endIndex: index + 2, isBoxed: boxed, isCodex: false)
    }

    /// The prefix reader and Grok's box reader share the scan. `boxed` selects
    /// which of them this panel is allowed to see.
    private static func acceptedPrefix(in line: Line, boxed: Bool) -> PromptPrefix? {
        guard let prefix = currentPromptPrefix(in: line), prefix.isBoxed == boxed else { return nil }
        return prefix
    }

    /// Codex indents each continuation row, including visual soft-wrap rows,
    /// by two display cells. Remove that presentation gutter before comparing
    /// the composer with pasted text; any additional leading spaces remain
    /// operator input.
    private static func stripCodexContinuationIndent(_ scalars: [StyledScalar]) -> [StyledScalar] {
        guard scalars.count >= 2,
              scalars[0].value == " ", !scalars[0].faint,
              scalars[1].value == " ", !scalars[1].faint else { return scalars }
        return Array(scalars.dropFirst(2))
    }

    /// Codex 0.159 renders its empty composer as a single `› ` row followed by
    /// this faint placeholder. Recognize only that exact, cursor-aligned shape;
    /// edited prompts and historical transcript rows remain unknown.
    private static func isEmptyCodexPrompt(_ line: Line, cursorX: Int) -> Bool {
        let placeholder = Array("Ask Codex to do anything".unicodeScalars)
        guard !line.softWrap, !line.wrapContinuation, cursorX == 2,
              line.scalars.count == placeholder.count + 2,
              line.scalars[0].value.value == 0x203A, !line.scalars[0].faint,
              line.scalars[1].value == " ", !line.scalars[1].faint else { return false }
        return zip(line.scalars.dropFirst(2), placeholder).allSatisfy {
            $0.value.value == $1.value && $0.faint
        }
    }

    /// Native permission menus captured from Claude 2.1.316, Codex 0.166.0,
    /// OpenCode 1.15.13 and Pi 0.81.1. A heading alone never guards a prompt.
    private static func supervisorDialog(_ lines: [Line], harness: String?, cursorY: Int, forSupervisor: Bool) -> String? {
        let type = harness?.lowercased()
        if forSupervisor, type == "pi", piChoice(lines) { return "choice" }
        let normalized = lines.map { collapsedLowercased($0.text) }
        for index in lines.indices {
            let text = normalized[index]
            if type == "codex", text.contains("press enter to confirm or esc to cancel") {
                let menu = normalized[max(0, index - 10)..<index]
                let selected = menu.contains { $0.hasPrefix("› ") && $0.dropFirst(2).first?.isNumber == true }
                if selected && menu.contains(where: { $0.contains("yes, proceed") })
                    && menu.contains(where: { $0.contains("no, and tell codex") })
                    && cursorY >= lines[max(0, index - 10)].y && cursorY <= lines[index].y {
                    return "permission"
                }
            }
            if type == "claude-code", text.contains("esc to cancel"), text.contains("tab to amend") {
                let menu = normalized[max(0, index - 8)..<index]
                if menu.contains(where: { $0.hasPrefix("❯ ") && $0.dropFirst(2).first?.isNumber == true })
                    && menu.contains(where: { $0.contains("yes") })
                    && menu.contains(where: { $0.contains(". no") })
                    && cursorY >= lines[max(0, index - 8)].y && cursorY <= lines[index].y {
                    return "permission"
                }
            }
            if type == "opencode", text.contains("⇆ select"), text.contains("enter confirm") {
                let menu = normalized[max(0, index - 12)..<index]
                if menu.contains(where: { $0.contains("┃") && $0.contains("permission required") })
                    && menu.contains(where: { $0.contains("allow once") && $0.contains("allow always") && $0.contains("reject") })
                    && cursorY >= lines[max(0, index - 12)].y && cursorY <= lines[index].y {
                    return "permission"
                }
            }
        }
        return nil
    }

    private static func piChoice(_ lines: [Line]) -> Bool {
        for footer in lines.indices {
            let text = collapsedLowercased(lines[footer].text)
            guard text == "↑↓ navigate enter select escape/ctrl+c cancel",
                  lines[..<footer].suffix(10).contains(where: { $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("→ ") }) else { continue }
            // A rendered old example above a live composer is not a dialog.
            // Pi puts only a horizontal rule and its two status rows below it.
            let after = lines.dropFirst(footer + 1).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !after.isEmpty, after.count <= 3,
                  after.first!.text.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "─" }) else { continue }
            if after.dropFirst().allSatisfy({ line in
                let value = line.text.trimmingCharacters(in: .whitespaces)
                return value.hasPrefix("~/") || value.hasPrefix("/") || value.contains("%/")
            }) { return true }
        }
        return false
    }

    private static let chooserOptionPairs: [(first: String, second: String, kind: PromptChooserKind)] = [
        ("no, exit", "yes, i trust this folder", .trust),
        ("yes, implement this plan", "no, keep planning", .plan),
        ("resume", "start a new conversation", .resume),
    ]

    static func isClaude(_ harness: String?) -> Bool {
        harness?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "claude-code"
    }

    /// The detector saw the shell itself in front (`terminal_type` `shell`).
    static func isShell(_ harness: String?) -> Bool {
        harness?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "shell"
    }

    /// C11H-272: with the shell in front no agent draws a composer, so a dead
    /// agent's composer or dialog left above the shell's prompt is history,
    /// not a draft. Only the cursor's own line, joined across soft wraps, may
    /// hold one (a `❯ git st` typed at a starship prompt still refuses).
    private static func cursorLogicalLine(_ lines: [Line], cursorIndex: Int) -> (lines: [Line], cursorIndex: Int) {
        func joined(_ upper: Int, _ lower: Int) -> Bool {
            lines[upper].softWrap && lines[lower].wrapContinuation && lines[upper].y + 1 == lines[lower].y
        }
        var start = cursorIndex
        while start > lines.startIndex, joined(start - 1, start) { start -= 1 }
        var end = cursorIndex
        while end + 1 < lines.endIndex, joined(end, end + 1) { end += 1 }
        return (Array(lines[start...end]), cursorIndex - start)
    }

    /// Option labels of Claude Code 2.1.325's rate-limit options menu
    /// (`tengu_rate_limit_options_menu`), lowercased. The menu shares its
    /// `What do you want to do?` title with the trial-expired and spend-limit
    /// menus, so an option, not the title, names it.
    private static let usageLimitOptions = [
        "stop and wait for limit to reset",
        "don\u{2019}t continue automatically",
        "don't continue automatically",
        "add funds to continue with usage credits",
        "wait for limit to reset",
    ]

    /// C11H-320: a Claude dialog that holds the session until someone answers
    /// it, read from the screen's bottom rows: `resume` or `usage_limit`.
    /// The dialog must be live: its footer (`Enter to confirm · Esc to …`) is
    /// the last non-blank row and a `❯ N.` option sits within the 14 rows
    /// above it. A quoted copy in the transcript, with a composer below it,
    /// never matches. Nil for anything else, including an incomplete read.
    static func claudeBlockingDialog(_ bottom: PromptRegionRows) -> PromptChooserKind? {
        guard let physical = boundedLines(bottom) else { return nil }
        if autoContinueBanner(physical) != nil { return .usageLimit }
        // A narrow panel wraps the dialog footers and options; read logical lines.
        let lines = logicalLines(physical, paintFull: bottom.wrapFlags ? nil : fullRows(bottom))
        guard let footerIndex = lines.indices.last(where: { !isBlank(lines[$0]) }) else { return nil }
        guard isBlockingDialogFooter(lines[footerIndex]) else { return nil }
        let window = lines[max(0, footerIndex - 14)..<footerIndex]
        let options = window.filter { isClaudeOption($0) || isClaudeOptionRow($0) }
        guard window.contains(where: isClaudeOption), !options.isEmpty else { return nil }
        let optionText = collapsedLowercased(options.map(\.text).joined(separator: " "))
        let windowText = collapsedLowercased(window.map(\.text).joined(separator: " "))
        if windowText.contains("resume this conversation?")
            || (optionText.contains("resume") && optionText.contains("start a new conversation")) {
            return .resume
        }
        if usageLimitOptions.contains(where: { optionText.contains($0) }) {
            return .usageLimit
        }
        return nil
    }

    /// Which rows reach the window's last column with a printed character.
    /// hc's paint, and a surface fed from it, carry no soft-wrap flags; such a
    /// row followed by text is how a wrap looks there.
    private static func fullRows(_ bottom: PromptRegionRows) -> [Bool] {
        let width = bottom.rows.map(\.cellRange.count).max() ?? 0
        let bytes = Array(bottom.text)
        return bottom.rows.map { row in
            guard width > 0, row.cellRange.count == width, let last = row.cellRange.last,
                  bottom.cells.indices.contains(last) else { return false }
            let cell = bottom.cells[last]
            guard cell.textLength > 0, cell.textOffset + cell.textLength <= bytes.count,
                  let text = String(bytes: bytes[cell.textOffset..<(cell.textOffset + cell.textLength)], encoding: .utf8)
            else { return false }
            return !text.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Wrapped rows joined into the logical lines they were printed as. A
    /// surface's soft-wrap flags decide alone: an unflagged row ends its line
    /// even when it fills the width. hc's paint has no flags (`paintFull` holds
    /// which rows fill the width): there a full row that is not a rule
    /// continues onto the next row, unless that row is blank, a rule, or opens
    /// a line of its own (`opensClaudeLine`). The window is bounded, so this is
    /// too; a first row whose start lies above the window stays as captured.
    private static func logicalLines(_ rows: [Line], paintFull: [Bool]? = nil) -> [Line] {
        var joined: [Line] = []
        var previousFull = false
        for (index, row) in rows.enumerated() {
            let unflagged = previousFull && !isBlank(row) && !isRule(row) && !opensClaudeLine(row)
            previousFull = paintFull.map { $0.count == rows.count && $0[index] && !isRule(row) } ?? false
            if let last = joined.last, row.y == last.y + 1,
               (last.softWrap && row.wrapContinuation) || unflagged {
                joined[joined.count - 1] = Line(y: row.y, softWrap: row.softWrap, wrapContinuation: last.wrapContinuation,
                                                scalars: last.scalars + row.scalars)
            } else {
                joined.append(row)
            }
        }
        return joined
    }

    private static func boundedLines(_ bottom: PromptRegionRows) -> [Line]? {
        guard bottom.complete, !bottom.rows.isEmpty, bottom.rows.count <= maxRows,
              bottom.cells.count <= maxCells, bottom.text.count <= maxTextBytes else { return nil }
        return makeLines(rows: bottom.rows, cells: bottom.cells, bytes: Array(bottom.text))
    }

    /// The reset time a Claude limit screen prints, read from the same bottom
    /// rows as `claudeBlockingDialog`. The text is used here and dropped.
    /// The logical text first, where a transcript line may name the zone; then
    /// the recognised banner's rows run together (a wrapped row is a split
    /// word), which holds the time on a source that kept no wrap flags.
    static func claudeLimitResetsAt(_ bottom: PromptRegionRows, now: Date) -> Date? {
        guard let lines = boundedLines(bottom) else { return nil }
        let text = logicalLines(lines, paintFull: bottom.wrapFlags ? nil : fullRows(bottom)).map(\.text).joined(separator: "\n")
        if let resets = ClaudeAgentReport.resetsAt(text, now: now, defaultZone: .current) { return resets }
        guard let banner = autoContinueBanner(lines) else { return nil }
        return ClaudeAgentReport.resetsAt(lines[banner].map(\.text).joined(), now: now, defaultZone: .current)
    }

    /// Claude's auto-continue wait (recorded at a real 5-hour limit): the
    /// composer gives way to `⚠ Usage limit reached · limit resets 8:10am`, then
    /// `Continuing automatically at 8:10am · Esc to cancel · …`. Recognised on
    /// physical rows, whatever wrapped them and whether the source keeps wrap
    /// flags (a surface, hc's paint, a surface fed from hc's paint): the last
    /// non-blank row closes a footer that opens `Continuing automatically` at
    /// most three rows above it, continues only through plain rows and holds
    /// `Esc to cancel`; the warning opens at most four rows above the footer,
    /// with nothing between but its own wrapped tail or blank rows. A composer,
    /// rule or other line below means the wait is over, and the transcript's
    /// quoted copy (`⏺ Usage limit reached · continuing …`) opens no footer.
    /// Returns the block, warning through last row.
    private static func autoContinueBanner(_ rows: [Line]) -> ClosedRange<Int>? {
        guard let last = rows.indices.last(where: { !isBlank(rows[$0]) }) else { return nil }
        var footer: Int?
        for index in stride(from: last, through: max(0, last - 3), by: -1) {
            let row = rows[index]
            if collapsedLowercased(row.text).hasPrefix("continuing automatically") { footer = index; break }
            if isBlank(row) || isRule(row) || opensClaudeLine(row) { return nil }
        }
        guard let footer, footer > 0,
              collapsedLowercased(rows[footer...last].map(\.text).joined()).contains("esc to cancel") else { return nil }
        for index in stride(from: footer - 1, through: max(0, footer - 4), by: -1) {
            let row = rows[index]
            if collapsedLowercased(row.text).hasPrefix("\u{26A0} usage limit reached") { return index...last }
            if isRule(row) || opensClaudeLine(row) { return nil }
        }
        return nil
    }

    /// A row that starts a line of Claude's own on these screens, so it never
    /// continues the row above it in hc's paint: the limit banner, a dialog
    /// footer, the composer, a transcript bullet or a numbered option.
    private static func opensClaudeLine(_ line: Line) -> Bool {
        let text = collapsedLowercased(line.text)
        let openers = ["\u{26A0}", "continuing automatically", "enter to confirm", "enter to select",
                       "\u{276F}", "\u{23FA}", "\u{23BF}"]
        return openers.contains { text.hasPrefix($0) } || isClaudeOptionRow(line)
    }

    private static func isBlockingDialogFooter(_ line: Line) -> Bool {
        let text = collapsedLowercased(line.text)
        return text.hasPrefix("enter to confirm") || text.hasPrefix("enter to select")
    }

    /// An unselected numbered option: leading spaces, then `N.`.
    private static func isClaudeOptionRow(_ line: Line) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard let dot = text.firstIndex(of: "."), dot > text.startIndex else { return false }
        return text[..<dot].allSatisfy(\.isNumber) && text[..<dot].count <= 2
    }

    /// The chooser at the live cursor, or nil. A dialog is supported when it
    /// is one of `chooserOptionPairs`.
    static func chooserKind(_ region: PromptRegionSnapshot, harness: String?) -> PromptChooserKind? {
        guard analyze(region, harness: harness).classification.state == .dialog,
              let lines = makeLines(region, bytes: Array(region.text)) else { return nil }
        return supportedChooserKind(lines, cursorY: region.cursorY)
    }

    private static func isSupportedDialog(_ lines: [Line], cursorY: Int) -> Bool {
        supportedChooserKind(lines, cursorY: cursorY) != nil
    }

    private static func supportedChooserKind(_ lines: [Line], cursorY: Int) -> PromptChooserKind? {
        for optionIndex in lines.indices where isClaudeOption(lines[optionIndex]) {
            let following = lines.dropFirst(optionIndex + 1).prefix(6)
            guard let footer = following.first(where: hasDialogFooter) else { continue }

            // The bounded capture can start below a heading that a narrow pane has
            // wrapped far above the cursor, so a chooser is recognized by its
            // selected option, its other option and its footer alone. The other
            // option can sit on either side of the selected row (selecting the
            // second option leaves the first above it).
            let selected = collapsedLowercased(lines[optionIndex].text)
            let before = lines[..<optionIndex].suffix(6)
            let siblings = collapsedLowercased((before + following).map(\.text).joined(separator: " "))
            let matched = chooserOptionPairs.first { pair in
                (selected.contains(pair.first) && siblings.contains(pair.second))
                    || (selected.contains(pair.second) && siblings.contains(pair.first))
            }

            // These layouts render the selection and its footer at the live
            // cursor. A stale chooser above a later composer must not block it.
            let cursorIsInChooser = lines[optionIndex].y <= cursorY && cursorY <= footer.y
            if cursorIsInChooser, let matched {
                return matched.kind
            }
        }
        return nil
    }

    private static func collapsedLowercased(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func hasDialogFooter(_ line: Line) -> Bool {
        let text = line.text.lowercased()
        return text.contains("enter to confirm")
            || text.contains("enter to select")
            || text.contains("press enter to continue")
    }

    private static func isClaudeOption(_ line: Line) -> Bool {
        var index = 0
        while index < line.scalars.count, line.scalars[index].value == " " { index += 1 }
        if index < line.scalars.count, line.scalars[index].value.value == 0x2502 {
            index += 1
            while index < line.scalars.count, line.scalars[index].value == " " { index += 1 }
        }
        return index + 1 < line.scalars.count
            && line.scalars[index].value.value == 0x276F
            && line.scalars[index + 1].value == " "
    }

    private static func stripLeadingBoxEdge(_ scalars: [StyledScalar]) -> [StyledScalar] {
        var index = 0
        while index < scalars.count, scalars[index].value == " " { index += 1 }
        guard index < scalars.count, scalars[index].value.value == 0x2502 else { return scalars }
        index += 1
        while index < scalars.count, scalars[index].value == " " { index += 1 }
        return Array(scalars.dropFirst(index))
    }

    private static func stripTrailingBoxEdge(_ scalars: [StyledScalar]) -> [StyledScalar] {
        var end = scalars.count
        while end > 0, isWhitespace(scalars[end - 1].value) { end -= 1 }
        guard end > 0, scalars[end - 1].value.value == 0x2502 else { return scalars }
        return Array(scalars[..<(end - 1)])
    }

    /// OpenCode draws the composer as heavy vertical bars (`┃`, U+2503), one
    /// row per visual line, from the top padding row down to the row above
    /// the model line (`┃  <model> · …`) and the `╹▀` footer. The cursor can
    /// sit on a blank row of a multi-line draft, so every composer row counts.
    /// One non-blank row that is not the idle hint is a draft. The rows are
    /// joined so a wrapped invitation matches the doorbell line.
    private static func openCodeComposer(_ lines: [Line], cursorIndex: Int, cursorX: Int) -> Analysis? {
        guard contentAfterMarker(lines[cursorIndex], marker: 0x2503) != nil else { return nil }
        var start = cursorIndex
        while start > 0,
              lines[start - 1].y + 1 == lines[start].y,
              contentAfterMarker(lines[start - 1], marker: 0x2503) != nil {
            start -= 1
        }
        var end = cursorIndex
        while end + 1 < lines.count,
              lines[end].y + 1 == lines[end + 1].y,
              contentAfterMarker(lines[end + 1], marker: 0x2503) != nil {
            end += 1
        }
        let hasModelFooter = isOpenCodeModelLine(lines[end]) && end + 1 < lines.count
            && lines[end].y + 1 == lines[end + 1].y && isOpenCodeFooter(lines[end + 1])
        if hasModelFooter { end -= 1 }
        guard end >= start else { return nil }
        var rows: [Analysis] = []
        for index in start...end {
            guard let content = contentAfterMarker(lines[index], marker: 0x2503) else { continue }
            rows.append(composerRow(content))
        }
        let joined = joinedComposer(rows)
        // A box that reaches the top of the capture (but not of the screen)
        // may hold typed rows above it: a multiline draft whose cursor sits on
        // a blank last row. Only a draft can be told from that fragment.
        if start == 0, lines[0].y > 0 {
            return joined.classification.state == .draft ? joined : nil
        }
        // Live OpenCode 1.18.30 draws its placeholder in a normal-weight gray,
        // so the prompt capture does not mark those cells faint. The idle
        // hint is exactly `Ask anything…` plus an optional quoted hint, even
        // when that hint wraps. Anything else is text the operator typed.
        guard joined.classification.state == .draft,
              let composer = joined.composerText,
              openCodePlaceholder(collapsedComposer(composer), allowClipped: hasModelFooter
                && lines[cursorIndex].scalars.firstIndex(where: { $0.value == "A" }) == cursorX) else {
            return joined
        }
        return Analysis(
            classification: PromptInputClassification(state: .suggestion, draftLength: nil),
            composerText: ""
        )
    }

    /// A `┃` row that contains a middle dot (`·`, U+00B7). The caller treats
    /// it as the model line only when the `╹▀` footer is the next row, so a
    /// draft that happens to contain a middle dot stays in the composer.
    private static func isOpenCodeModelLine(_ line: Line) -> Bool {
        guard let content = contentAfterMarker(line, marker: 0x2503) else { return false }
        return content.contains { $0.value.value == 0x00B7 }
    }

    /// OpenCode's composer footer. The first glyph is `╹` (U+2579).
    private static func isOpenCodeFooter(_ line: Line) -> Bool {
        guard let first = line.scalars.map(\.value.value).first(where: { !isWhitespaceValue($0) }) else {
            return false
        }
        return first == 0x2579
    }

    /// OpenCode's idle hint. The ellipsis is the one it draws (U+2026) or three dots.
    private static func openCodePlaceholder(_ text: String, allowClipped: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Ask anything"
        guard trimmed.hasPrefix(prefix) else { return false }
        let rest = trimmed.dropFirst(prefix.count)
        let hint: Substring
        if rest.first == "…" {
            hint = rest.dropFirst()
        } else if rest.hasPrefix("...") {
            hint = rest.dropFirst(3)
        } else {
            return false
        }
        let body = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return true }
        guard body.first == "\"" else { return false }
        if body.last == "\"" { return true }
        // OpenCode 2.0.25 clips these home hints before drawing, including
        // the closing quote. Require its complete composer and the cursor at
        // the start of the hint; arbitrary unfinished quoted drafts stay drafts.
        let clipped = String(body.dropFirst())
        return allowClipped && clipped.count >= 8 && [
            "Fix a TODO in the codebase", "What is the tech stack of this project?", "Fix broken tests"
        ].contains { $0.hasPrefix(clipped) }
    }

    /// Pi's composer is every row between the two rules around the cursor, not
    /// exactly one row. An empty row is idle. Typed text is a draft, including
    /// a multi-line draft whose cursor sits on a blank row. The rows are
    /// joined so a wrapped invitation matches the doorbell line. A `❯` or `›`
    /// row is not this shape.
    private static func piComposer(_ lines: [Line], cursorIndex: Int) -> Analysis? {
        if isPiBorder(lines[cursorIndex]) { return nil }
        var above = cursorIndex - 1
        while above >= 0,
              lines[above].y + 1 == lines[above + 1].y,
              !isPiBorder(lines[above]) {
            above -= 1
        }
        guard above >= 0,
              isPiBorder(lines[above]),
              lines[above].y + 1 == lines[above + 1].y else {
            return nil
        }
        var below = cursorIndex + 1
        while below < lines.count,
              lines[below - 1].y + 1 == lines[below].y,
              !isPiBorder(lines[below]) {
            below += 1
        }
        guard below < lines.count,
              isPiBorder(lines[below]),
              lines[below - 1].y + 1 == lines[below].y else {
            return nil
        }
        let body = lines[(above + 1)..<below]
        if body.contains(where: { currentPromptPrefix(in: $0) != nil }) { return nil }
        return joinedComposer(body.map { composerRow($0.scalars) })
    }

    /// One composer across several visual rows. Blank rows drop out. A single
    /// Pi row keeps its leading cursor space. A wrapped invitation joins with
    /// newlines so the doorbell compare can unwrap it.
    private static func joinedComposer(_ rows: [Analysis]) -> Analysis {
        var parts: [String] = []
        var faint = false
        for row in rows {
            switch row.classification.state {
            case .draft:
                if let text = row.composerText, !text.isEmpty {
                    parts.append(text)
                }
            case .suggestion:
                faint = true
            case .empty, .dialog, .unknown, .unavailable:
                break
            }
        }
        if parts.isEmpty {
            return Analysis(
                classification: PromptInputClassification(
                    state: faint ? .suggestion : .empty,
                    draftLength: nil
                ),
                composerText: ""
            )
        }
        let joined = parts.joined(separator: "\n")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return Analysis(
            classification: PromptInputClassification(state: .draft, draftLength: trimmed.count),
            composerText: joined
        )
    }

    /// Newlines and the indent on a continuation are presentation. The
    /// doorbell compare uses the same collapse.
    private static func collapsedComposer(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Text after a leading marker and its gutter, or nil when the marker is
    /// not the row's first glyph.
    private static func contentAfterMarker(_ line: Line, marker: UInt32) -> [StyledScalar]? {
        var index = 0
        while index < line.scalars.count, line.scalars[index].value == " " { index += 1 }
        guard index < line.scalars.count, line.scalars[index].value.value == marker else { return nil }
        index += 1
        while index < line.scalars.count, line.scalars[index].value == " " { index += 1 }
        return Array(line.scalars.dropFirst(index))
    }

    private static func composerRow(_ scalars: [StyledScalar]) -> Analysis {
        var typed: [Unicode.Scalar] = []
        var hasTypedText = false
        var hasFaintSuggestion = false
        for item in scalars {
            guard !item.faint else {
                if !isWhitespace(item.value) { hasFaintSuggestion = true }
                continue
            }
            typed.append(item.value)
            if !isWhitespace(item.value) { hasTypedText = true }
        }
        while let last = typed.last, isWhitespace(last) { typed.removeLast() }
        guard hasTypedText else {
            return Analysis(
                classification: PromptInputClassification(
                    state: hasFaintSuggestion ? .suggestion : .empty,
                    draftLength: nil
                ),
                composerText: ""
            )
        }
        let trimmed = trimWhitespace(typed)
        return Analysis(
            classification: PromptInputClassification(state: .draft, draftLength: trimmed.count),
            composerText: String(String.UnicodeScalarView(typed))
        )
    }

    /// Grok closes its composer with `╰── Grok 4.7 … ─╯`. That footer is the
    /// bottom of the box, not text the operator typed. A pure horizontal rule
    /// is handled by `isRule`.
    private static func isClosingBoxEdge(_ line: Line) -> Bool {
        let values = line.scalars.map(\.value.value)
        guard let first = values.first(where: { !isWhitespaceValue($0) }) else { return false }
        guard first == 0x2570 || first == 0x2514 else { return false }
        return values.contains(where: { (0x2500...0x257F).contains($0) })
    }

    /// Pi's border is an unindented rule whose box-drawing run reaches the
    /// row's last cell. Captured rows are padded to the panel width, so a
    /// short rule typed into the composer has trailing blank cells and is
    /// draft content. An indented rule belongs to another harness.
    private static func isPiBorder(_ line: Line) -> Bool {
        guard let first = line.scalars.first, !isWhitespace(first.value),
              let last = line.scalars.last, !isWhitespace(last.value) else { return false }
        return isRule(line)
    }

    private static func isRule(_ line: Line) -> Bool {
        let values = line.scalars.map(\.value.value)
        return values.contains(where: { (0x2500...0x257F).contains($0) })
            && values.allSatisfy { (0x2500...0x257F).contains($0) || isWhitespaceValue($0) }
    }

    private static func isBlank(_ line: Line) -> Bool {
        line.scalars.allSatisfy { isWhitespace($0.value) }
    }

    private static func trimWhitespace(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var start = 0
        var end = scalars.count
        while start < end, isWhitespace(scalars[start]) { start += 1 }
        while end > start, isWhitespace(scalars[end - 1]) { end -= 1 }
        return Array(scalars[start..<end])
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isWhitespaceValue(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        return isWhitespace(scalar)
    }
}
