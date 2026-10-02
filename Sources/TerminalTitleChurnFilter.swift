import Foundation

/// Admit meaningful OSC title changes before notifying metadata/titlebar observers.
/// Each terminal owns its baseline, independently of metadata precedence and flushes.
struct TerminalTitleChurnFilter {
    private(set) var lastPublishedTitle: String?

    mutating func admit(_ next: String) -> Bool {
        guard Self.shouldPublish(previous: lastPublishedTitle, next: next) else { return false }
        lastPublishedTitle = next
        return true
    }

    static func shouldPublish(previous: String?, next: String) -> Bool {
        let next = next.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = previous?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An empty OSC title is a clear, while a spinner is never a clear.
        if next.isEmpty { return !previous.isEmpty }
        let label = meaningfulText(next)
        guard !label.isEmpty else { return false }
        return label != meaningfulText(previous)
    }

    private static func meaningfulText(_ title: String) -> String {
        // Adjacent glyphs can be Braille words or art, not an animation frame.
        // Preserve these just as upstream's title filter does.
        var precedingGlyph = false
        for character in title {
            let glyph = isSpinnerFrame(character) || isBraille(character)
            if glyph && precedingGlyph { return title }
            precedingGlyph = glyph
        }
        let tokens = title.split(whereSeparator: { $0.isWhitespace })
        let kept = tokens.filter { token in
            !(token.count == 1 && isSpinnerFrame(token.first!))
        }
        guard kept.count != tokens.count else { return title }
        return kept.joined(separator: " ")
    }

    private static func isSpinnerFrame(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        switch value {
        case 0x280B, 0x2819, 0x2839, 0x2838, 0x283C,
             0x2834, 0x2826, 0x2827, 0x2807, 0x280F,
             0x28F7, 0x28EF, 0x28DF, 0x287F, 0x28BF, 0x28FB, 0x28FD, 0x28FE,
             0x2731...0x273D, 0x2722, 0x00B7,
             0x25D0...0x25D3, 0x25F4...0x25F7:
            return true
        default:
            return false
        }
    }

    private static func isBraille(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return (0x2800...0x28FF).contains(value)
    }
}
