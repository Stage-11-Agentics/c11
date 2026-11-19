import AppKit
import SwiftUI

/// The operator's icon picker for a workspace group or a workspace, shown in a
/// popover (never a modal: agents cannot reach it). One click on an emoji sets
/// it; the field searches by name and accepts any typed emoji, or `sf:` and a
/// symbol name; Clear removes the icon. Every region keeps a fixed size, so
/// typing never moves a button.
struct SidebarIconPicker: View {
    let title: String
    /// What draws today, shown in the preview until the operator types.
    let current: SidebarIconGlyph?
    var focusTarget: WorkspaceGroupEditorFocusTarget? = nil
    /// Nil clears the icon. Throws to keep the error inside the picker.
    let onSubmit: (SidebarIconGlyph?) throws -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var errorMessage: String?
    @State private var submitted = false
    @FocusState private var fieldFocused: Bool

    static let columns = 8
    static let cell: CGFloat = 32
    static let spacing: CGFloat = 4
    static let visibleRows = 5

    private static var gridHeight: CGFloat {
        CGFloat(visibleRows) * cell + CGFloat(visibleRows - 1) * spacing
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The cells on show: the common page, or what the field resolves to.
    private var cells: [SidebarIconGlyph] {
        Self.cells(for: trimmedQuery)
    }

    /// What Return sets: the first cell while the operator is typing.
    private var candidate: SidebarIconGlyph? {
        trimmedQuery.isEmpty ? nil : cells.first
    }

    /// One emoji typed or pasted, `sf:` and a symbol name, search results by
    /// Unicode name, then a bare symbol name nothing else matched.
    static func cells(for query: String,
                      symbolExists: (String) -> Bool = SidebarIconGlyph.symbolExists) -> [SidebarIconGlyph] {
        guard !query.isEmpty else { return SidebarEmojiCatalog.common.map { .text($0) } }
        if query.hasPrefix("sf:") {
            let name = String(query.dropFirst(3))
            return symbolExists(name) ? [.symbol(name)] : []
        }
        if !SidebarIconGlyph.isSymbolNameShaped(query.replacingOccurrences(of: " ", with: "")) {
            // Not a name to search: each emoji or symbol typed or inserted is
            // a cell (an emoji sequence is one character). Letters are words
            // in another language, which the English names cannot match.
            var seen = Set<String>()
            return query.compactMap { character -> SidebarIconGlyph? in
                let glyph = String(character)
                guard isIconCharacter(character), seen.insert(glyph).inserted else { return nil }
                return .text(glyph)
            }
        }
        let found: [SidebarIconGlyph] = SidebarEmojiCatalog.search(query).map { .text($0.glyph) }
        if found.isEmpty, symbolExists(query) { return [.symbol(query)] }
        return found
    }

    /// An emoji in any presentation, or a symbol character; not a letter,
    /// digit, punctuation mark, space or control. Emoji come first: ℹ, Ⓜ and
    /// 🅰 are also letters to Unicode, and a pasted keycap may lack U+FE0F.
    static func isIconCharacter(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }
        if scalars.contains(where: { $0.properties.isEmojiPresentation || $0 == "\u{FE0F}" }) { return true }
        if scalars.contains("\u{20E3}"), "0123456789#*".unicodeScalars.contains(first) { return true }
        if first.properties.isEmoji, !first.isASCII { return true }
        if character.isWhitespace || character.isLetter || character.isNumber || character.isPunctuation { return false }
        return !SidebarIconGlyph.containsControl(String(character))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title).font(.headline)
            HStack(spacing: 8) {
                preview
                TextField(String(localized: "sidebarIcon.picker.search",
                                 defaultValue: "Search or type an emoji"),
                          text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { if let candidate { apply(candidate) } }
                    .accessibilityIdentifier("sidebar-icon-picker-field")
                // An icon, not a labelled button: the label does not fit beside
                // Clear Icon and Cancel in every language.
                Button {
                    fieldFocused = true
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 15))
                        .frame(width: 24, height: Self.cell)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(String(localized: "sidebarIcon.picker.characterViewer.help",
                             defaultValue: "Open the macOS Character Viewer; the emoji you pick lands in the field."))
                .accessibilityLabel(Text(String(localized: "sidebarIcon.picker.characterViewer",
                                                defaultValue: "Emoji & Symbols…")))
                .accessibilityIdentifier("sidebar-icon-picker-character-viewer")
            }
            grid
            Text(verbatim: statusLine)
                .foregroundColor(errorMessage == nil ? .secondary : .red)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
                .accessibilityHidden(statusLine == " ")
            HStack {
                Button(String(localized: "workspaceGroup.clearIcon", defaultValue: "Clear Icon")) { apply(nil) }
                    .accessibilityIdentifier("sidebar-icon-picker-clear")
                Spacer()
                Button(String(localized: "workspaceGroup.cancel", defaultValue: "Cancel"), action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: CGFloat(Self.columns) * Self.cell + CGFloat(Self.columns - 1) * Self.spacing + 32)
        .onAppear {
            query = ""
            errorMessage = nil
            submitted = false
            fieldFocused = false
        }
        .task {
            // A menu-driven popover can appear before its field is attached.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            guard !Task.isCancelled else { return }
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in errorMessage = nil }
        .onExitCommand(perform: onDismiss)
        .onDisappear {
            fieldFocused = false
            focusTarget?.restore()
        }
    }

    private var preview: some View {
        let shown = candidate ?? (trimmedQuery.isEmpty ? current : nil)
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
            if let shown {
                SidebarIconGlyphView(glyph: shown, size: 18)
                    .frame(width: 24, height: 24)
            }
        }
        .frame(width: Self.cell, height: Self.cell)
        .accessibilityHidden(true)
    }

    private var grid: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: Self.spacing), count: Self.columns),
                      alignment: .leading, spacing: Self.spacing) {
                ForEach(Array(cells.enumerated()), id: \.offset) { index, glyph in
                    SidebarIconPickerCell(glyph: glyph, isCandidate: index == 0 && candidate != nil) { apply(glyph) }
                        .accessibilityIdentifier("sidebar-icon-picker-cell-\(index)")
                }
            }
        }
        .frame(height: Self.gridHeight)
        .accessibilityIdentifier("sidebar-icon-picker-grid")
    }

    private var statusLine: String {
        if let errorMessage { return errorMessage }
        if !trimmedQuery.isEmpty && cells.isEmpty {
            return String(localized: "sidebarIcon.picker.noMatches",
                          defaultValue: "No matches. Try another word, or open Emoji & Symbols.")
        }
        return " "
    }

    private func apply(_ glyph: SidebarIconGlyph?) {
        guard !submitted else { return }
        do {
            try onSubmit(glyph)
            submitted = true
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SidebarIconPickerCell: View {
    let glyph: SidebarIconGlyph
    let isCandidate: Bool
    let action: () -> Void
    @State private var hovering = false

    private var label: String {
        switch glyph {
        case .symbol(let name): return name
        case .text(let text): return SidebarEmojiCatalog.name(of: text).isEmpty ? text : SidebarEmojiCatalog.name(of: text)
        }
    }

    var body: some View {
        Button(action: action) {
            SidebarIconGlyphView(glyph: glyph, size: 18)
                .frame(width: SidebarIconPicker.cell, height: SidebarIconPicker.cell)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(hovering ? 0.22 : (isCandidate ? 0.12 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// One opening of the picker from a workspace's context menu: the workspaces
/// it writes (every context target) and the focus to restore after.
struct SidebarIconPickerRequest: Identifiable {
    let id = UUID()
    let targetIds: [UUID]
    let focusTarget: WorkspaceGroupEditorFocusTarget?
}
