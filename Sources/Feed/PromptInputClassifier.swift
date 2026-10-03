import Foundation

enum PromptInputState: String, Equatable, Sendable {
    case empty
    case suggestion
    case draft
    case dialog
    case unknown
    case unavailable
}

struct PromptInputClassification: Equatable, Sendable {
    let state: PromptInputState
    let draftLength: Int?

    static let unknown = Self(state: .unknown, draftLength: nil)

    func responseFields(source: String?, observedAtMs: Int64?) -> [String: Any] {
        [
            "input_state": state.rawValue,
            "draft_length": draftLength.map { $0 as Any } ?? NSNull(),
            "source": source.map { $0 as Any } ?? NSNull(),
            "observed_at_ms": observedAtMs.map { $0 as Any } ?? NSNull(),
        ]
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

    static func activeScreen(_ region: PromptRegionSnapshot) -> Self {
        Self(
            classification: PromptInputClassifier.classify(region),
            source: "active_screen",
            observedAtMs: Int64((Date().timeIntervalSince1970 * 1000).rounded())
        )
    }

    var responseFields: [String: Any] {
        classification.responseFields(source: source, observedAtMs: observedAtMs)
    }
}

struct PromptRegionCell: Equatable, Sendable {
    let textOffset: Int
    let textLength: Int
    let faint: Bool
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
}

enum PromptInputClassifier {
    static let maxRows = 16
    static let maxCells = 4096
    static let maxTextBytes = 16 * 1024

    private struct StyledScalar {
        let value: Unicode.Scalar
        let faint: Bool
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

    static func classify(_ region: PromptRegionSnapshot) -> PromptInputClassification {
        analyze(region).classification
    }

    /// Transiently returns the typed text for an exact composer comparison.
    /// Suggestions, dialogs, incomplete captures, and unsupported layouts do
    /// not expose text to callers.
    static func composerText(_ region: PromptRegionSnapshot) -> String? {
        let analysis = analyze(region)
        guard analysis.classification.state == .draft else { return nil }
        return analysis.composerText
    }

    private static func analyze(_ region: PromptRegionSnapshot) -> Analysis {
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

        if isSupportedDialog(lines, cursorY: region.cursorY) {
            return Analysis(
                classification: PromptInputClassification(state: .dialog, draftLength: nil),
                composerText: nil
            )
        }

        if isEmptyCodexPrompt(lines[cursorIndex], cursorX: region.cursorX) {
            return Analysis(
                classification: PromptInputClassification(state: .suggestion, draftLength: nil),
                composerText: nil
            )
        }

        guard let promptIndex = lines.indices.reversed().first(where: { index in
            lines[index].y <= region.cursorY && currentPromptPrefix(in: lines[index]) != nil
        }), promptIndex <= cursorIndex,
              let prefix = currentPromptPrefix(in: lines[promptIndex]) else {
            return Analysis(classification: .unknown, composerText: nil)
        }

        var typedScalars: [Unicode.Scalar] = []
        var hasTypedText = false
        var hasFaintSuggestion = false
        var previousIndex = promptIndex
        var stoppedAtRule = false

        for index in promptIndex..<lines.count {
            let line = lines[index]
            if index > promptIndex {
                let previous = lines[previousIndex]
                if line.y != previous.y + 1 || previous.softWrap != line.wrapContinuation {
                    return Analysis(classification: .unknown, composerText: nil)
                }
                if isRule(line) {
                    // The composer's closing rule sits below the cursor row. A rule
                    // above it means the typed row was never reached: not empty.
                    if line.y <= region.cursorY {
                        return Analysis(classification: .unknown, composerText: nil)
                    }
                    stoppedAtRule = true
                    break
                }
                // Blank rows inside a multiline composer (leading or embedded) are
                // content; only a blank row past the cursor row ends the scan.
                if isBlank(line), line.y > region.cursorY, !previous.softWrap {
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
            for item in content {
                guard !item.faint else {
                    if !isWhitespace(item.value) { hasFaintSuggestion = true }
                    continue
                }
                rowScalars.append(item.value)
                if !isWhitespace(item.value) { hasTypedText = true }
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

        let trimmed = trimWhitespace(typedScalars)
        return Analysis(
            classification: PromptInputClassification(state: .draft, draftLength: trimmed.count),
            composerText: String(String.UnicodeScalarView(typedScalars))
        )
    }

    private static func makeLines(_ region: PromptRegionSnapshot, bytes: [UInt8]) -> [Line]? {
        var result: [Line] = []
        result.reserveCapacity(region.rows.count)

        for row in region.rows {
            guard row.cellRange.lowerBound >= 0,
                  row.cellRange.upperBound <= region.cells.count else { return nil }
            var scalars: [StyledScalar] = []
            for cell in region.cells[row.cellRange] {
                guard cell.textOffset >= 0, cell.textLength >= 0,
                      cell.textOffset <= bytes.count,
                      cell.textLength <= bytes.count - cell.textOffset else { return nil }
                guard cell.textLength > 0 else { continue }
                let start = cell.textOffset
                let end = start + cell.textLength
                let text = String(decoding: bytes[start..<end], as: UTF8.self)
                for scalar in text.unicodeScalars {
                    scalars.append(StyledScalar(value: scalar, faint: cell.faint))
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
              line.scalars[index + 1].value.value == 0x00A0,
              !line.scalars[index].faint,
              !line.scalars[index + 1].faint else { return nil }
        return PromptPrefix(endIndex: index + 2, isBoxed: boxed, isCodex: false)
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

    private static let chooserOptionPairs: [(String, String)] = [
        ("no, exit", "yes, i trust this folder"),
        ("yes, implement this plan", "no, keep planning"),
    ]

    private static func isSupportedDialog(_ lines: [Line], cursorY: Int) -> Bool {
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
            let isChooser = chooserOptionPairs.contains { first, second in
                (selected.contains(first) && siblings.contains(second))
                    || (selected.contains(second) && siblings.contains(first))
            }

            // These layouts render the selection and its footer at the live
            // cursor. A stale chooser above a later composer must not block it.
            let cursorIsInChooser = lines[optionIndex].y <= cursorY && cursorY <= footer.y
            if cursorIsInChooser && isChooser {
                return true
            }
        }
        return false
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
