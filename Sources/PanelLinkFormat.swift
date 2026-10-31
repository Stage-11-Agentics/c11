import Foundation

/// Presentation only. UUID parsing and native activation belong to PanelLinkTarget.
struct PanelLinkFormat {
    enum Kind: String {
        case panel, workspace
    }

    static let maximumTitleScalars = 256

    let kind: Kind
    let id: UUID
    let title: String

    init(kind: Kind, id: UUID, title: String) {
        self.kind = kind
        self.id = id
        let sanitized = Self.sanitizedTitle(title)
        self.title = sanitized.isEmpty ? Self.url(kind: kind, id: id) : sanitized
    }

    static func url(kind: Kind, id: UUID) -> String {
        "c11://\(kind.rawValue)/\(id.uuidString.lowercased())"
    }

    var url: String { Self.url(kind: kind, id: id) }

    var markdown: String {
        // Escape label delimiters and inline markup while keeping ordinary
        // punctuation readable in terminals and other raw Markdown output.
        let label = title.unicodeScalars.map { scalar -> String in
            let needsEscape = "\\[]*_`<>&!".unicodeScalars.contains(scalar)
            return (needsEscape ? "\\" : "") + String(scalar)
        }.joined()
        return "[\(label)](\(url))"
    }

    var osc8: String {
        "\u{1B}]8;;\(url)\u{1B}\\\(title)\u{1B}]8;;\u{1B}\\"
    }

    /// One bounded line, with no terminal controls or bidirectional overrides.
    /// Preserve joiners used by ordinary language and emoji.
    static func sanitizedTitle(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if scalar.properties.generalCategory == .control { continue }
            if scalar.properties.generalCategory == .format,
               scalar.value != 0x200C, scalar.value != 0x200D { continue }
            let needed = pendingSpace ? 2 : 1
            if scalars.count + needed >= maximumTitleScalars {
                scalars.append("…")
                break
            }
            if pendingSpace { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
