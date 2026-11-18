import AppKit
import SwiftUI

/// One sidebar icon: an SF Symbol or a single emoji. A workspace group's `icon`
/// and a workspace's `icon` metadata both resolve to this, so one picker writes
/// both and one view draws both in the same fixed slot.
enum SidebarIconGlyph: Hashable {
    case symbol(String)
    case text(String)

    /// The value a workspace group stores: a bare symbol name (what every
    /// earlier build wrote and draws) or the emoji itself.
    var groupValue: String {
        switch self {
        case .symbol(let name): return name
        case .text(let glyph): return glyph
        }
    }

    /// The value `set-workspace-icon` writes: `sf:<name>` or the emoji itself.
    var workspaceMetadataValue: String {
        switch self {
        case .symbol(let name): return "sf:" + name
        case .text(let glyph): return glyph
        }
    }

    /// `workspaceMetadataValue`, refused before the write when the workspace
    /// store would refuse it (an `sf:` name past the icon limit), so the picker
    /// shows why instead of closing as if it worked.
    func checkedWorkspaceMetadataValue() throws -> String {
        let value = workspaceMetadataValue
        do {
            try WorkspaceMetadataValidator.validate(key: WorkspaceMetadataKey.icon, value: value)
        } catch WorkspaceMetadataValidator.ValidationError.valueTooLong(_, let limit) {
            throw SidebarIconError.workspaceIconTooLong(limit: limit)
        } catch let error as WorkspaceMetadataValidator.ValidationError {
            throw SidebarIconError.rejected(error.message)
        }
        return value
    }

    static func symbolExists(_ name: String) -> Bool {
        !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The value a group may store, or nil when `raw` is neither an SF Symbol
    /// name (bare or `sf:`, stored bare) nor exactly one emoji or character.
    static func normalizedGroupIcon(_ raw: String,
                                    symbolExists: (String) -> Bool = SidebarIconGlyph.symbolExists) -> String? {
        forGroupIcon(raw, symbolExists: symbolExists)?.groupValue
    }

    /// How a stored group icon draws: nil (the caller's `folder.fill`) for an
    /// unset or unknown value, so a saved symbol draws exactly as before.
    static func forGroupIcon(_ raw: String?,
                             symbolExists: (String) -> Bool = SidebarIconGlyph.symbolExists) -> SidebarIconGlyph? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("sf:") {
            let name = String(trimmed.dropFirst(3))
            return symbolExists(name) ? .symbol(name) : nil
        }
        if isSymbolNameShaped(trimmed), symbolExists(trimmed) { return .symbol(trimmed) }
        guard trimmed.count == 1, !containsControl(trimmed) else { return nil }
        return .text(trimmed)
    }

    /// How a workspace's `icon` metadata draws: `sf:<name>` or a bare known
    /// symbol name as a symbol, otherwise its first character (one emoji), or
    /// nil when blank or an unknown `sf:` name.
    static func forWorkspaceIcon(_ raw: String?,
                                 symbolExists: (String) -> Bool = SidebarIconGlyph.symbolExists) -> SidebarIconGlyph? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("sf:") {
            let name = String(trimmed.dropFirst(3))
            return symbolExists(name) ? .symbol(name) : nil
        }
        if isSymbolNameShaped(trimmed), symbolExists(trimmed) { return .symbol(trimmed) }
        guard !containsControl(trimmed), let first = trimmed.first else { return nil }
        return .text(String(first))
    }

    /// Printable ASCII without spaces: the shape of every SF Symbol name. An
    /// emoji fails it, so drawing one never pays for a symbol lookup.
    static func isSymbolNameShaped(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    /// C0/C1 controls and line breaks. Not `CharacterSet.controlCharacters`:
    /// that holds format characters too, and an emoji family or a subdivision
    /// flag is built from them (the zero-width joiner, tag characters).
    static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
        }
    }
}

enum SidebarIconError: LocalizedError, Equatable {
    case workspaceIconTooLong(limit: Int)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .workspaceIconTooLong(let limit):
            return String(localized: "sidebarIcon.error.workspaceTooLong",
                          defaultValue: "Too long for a workspace icon: \(limit) characters at most. Pick an emoji or a shorter symbol name.")
        case .rejected(let message):
            return message
        }
    }
}

/// Draws a `SidebarIconGlyph` at `size` points. The caller frames it, so an
/// emoji and a symbol always take the same box; a symbol draws exactly like
/// `Image(systemName:).font(.system(size:))`, and an emoji shrinks to fit.
struct SidebarIconGlyphView: View {
    let glyph: SidebarIconGlyph
    let size: CGFloat

    var body: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size))
        case .text(let text):
            Text(verbatim: text)
                .font(.system(size: size))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

/// The emoji the picker offers: a fixed first page, and every single-scalar
/// emoji by its Unicode name for search.
enum SidebarEmojiCatalog {
    struct Entry: Hashable {
        let glyph: String
        /// Lowercased Unicode name, e.g. "rocket".
        let name: String
    }

    /// Five rows of eight: the page shown before the operator types.
    static let common: [String] = [
        "📁", "🗂️", "📦", "🚀", "🛠️", "🔧", "⚙️", "🧪",
        "🧠", "🤖", "💡", "🔥", "⭐️", "✨", "🎯", "📌",
        "🏁", "🐛", "🔒", "🔑", "🌐", "☁️", "💻", "🖥️",
        "📱", "📊", "📈", "📝", "📚", "🎨", "🎵", "🎮",
        "🏠", "💼", "💰", "❤️", "✅", "⚠️", "🌱", "🌙",
    ]

    static let all: [Entry] = build()

    /// The lowercased Unicode name of an emoji's first scalar, for search and
    /// accessibility; empty when it has none.
    static func name(of glyph: String) -> String {
        glyph.unicodeScalars.first?.properties.name?.lowercased() ?? ""
    }

    /// Entries whose name holds every word of `query`, exact names first, then
    /// names with a word starting with the query, then the rest, each in
    /// Unicode order.
    static func search(_ query: String, in entries: [Entry] = all) -> [Entry] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let matches = entries.filter { entry in words.allSatisfy { entry.name.contains($0) } }
        func rank(_ entry: Entry) -> Int {
            if entry.name == needle { return 0 }
            let nameWords = entry.name.split(separator: " ")
            if words.allSatisfy({ word in nameWords.contains { $0.hasPrefix(word) } }) { return 1 }
            return 2
        }
        return matches.enumerated()
            .sorted { lhs, rhs in
                let l = rank(lhs.element), r = rank(rhs.element)
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func build() -> [Entry] {
        let ranges: [ClosedRange<UInt32>] = [0x00A9...0x00AE, 0x203C...0x3299, 0x1F000...0x1FAFF]
        var entries: [Entry] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let properties = scalar.properties
                // Skin-tone modifiers and regional-indicator letters only make
                // sense inside a sequence; the hair components likewise.
                guard properties.isEmoji, !properties.isEmojiModifier,
                      !(0x1F1E6...0x1F1FF).contains(value),
                      let name = properties.name?.lowercased(),
                      !name.hasPrefix("emoji component") else { continue }
                let glyph = properties.isEmojiPresentation
                    ? String(scalar) : String(scalar) + "\u{FE0F}"
                entries.append(Entry(glyph: glyph, name: name))
            }
        }
        return entries
    }
}
