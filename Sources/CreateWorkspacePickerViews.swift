import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Views behind the New Workspace picker (C11-240): search field, key monitor,
// list row, pin tile. State and side effects live in CreateWorkspaceSheet.

// MARK: - Focus request

/// A request to move focus into the search field. `id` changes on every
/// request so repeated requests are seen as changes.
struct SearchFocusRequest: Equatable {
    var id: Int = 0
    /// True selects the existing text (⌘F); false parks the caret at the end
    /// (type-to-search).
    var selectAll: Bool = false
}

// MARK: - Search field (NSSearchField)

/// An `NSSearchField` so ↑↓, ⏎, ⌥⏎ and Esc arrive through
/// `control(_:textView:doCommandBy:)` while focus stays in the field.
struct PickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: SearchFocusRequest
    let onMove: (Int) -> Void
    let onSubmit: (_ optionHeld: Bool) -> Void
    /// Esc with an empty query.
    let onEscape: () -> Void
    /// Tab. Return true when the key was used.
    var onTab: () -> Bool = { false }

    final class Field: NSSearchField {
        var didInitialFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !didInitialFocus else { return }
            didInitialFocus = true
            // The hosting controller assigns its own first responder during the
            // first layout; claim focus after it, twice to be safe.
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, let window = self.window else { return }
                if !(window.firstResponder is NSTextView) { window.makeFirstResponder(self) }
            }
        }
    }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.appearance = NSAppearance(named: .darkAqua)
        field.font = .systemFont(ofSize: 12)
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel(placeholder)
        // The trailing "N of M" overlay owns that corner; Esc clears the query.
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() as? NSTextView {
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
        }
        field.placeholderString = placeholder
        if context.coordinator.lastFocusId != focusRequest.id {
            context.coordinator.lastFocusId = focusRequest.id
            let request = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() as? NSTextView {
                    let end = (editor.string as NSString).length
                    editor.setSelectedRange(request.selectAll
                        ? NSRange(location: 0, length: end)
                        : NSRange(location: end, length: 0))
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PickerSearchField
        var lastFocusId: Int

        init(parent: PickerSearchField) {
            self.parent = parent
            self.lastFocusId = parent.focusRequest.id
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(+1)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit(NSEvent.modifierFlags.contains(.option))
                return true
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()
            case #selector(NSResponder.cancelOperation(_:)):
                if !parent.text.isEmpty {
                    parent.text = ""
                    (control as? NSTextField)?.stringValue = ""
                } else {
                    parent.onEscape()
                }
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Key monitor

/// Window-scoped key handling that SwiftUI cannot express: type-to-search from
/// outside a text field, ⌘1–⌘9, ⌘F, ↑↓ when focus is not in a text field, and
/// Esc when focus is in some other text field.
struct PickerKeyMonitor: NSViewRepresentable {
    /// ⌘1…⌘9. Return true when handled.
    let onPinShortcut: (Int) -> Bool
    let onFocusSearch: () -> Void
    let onTypeToSearch: (String) -> Void
    let onArrow: (Int) -> Void
    /// Esc while focus is outside the search field. Return true when handled.
    let onEscapeOutsideSearch: () -> Bool

    final class MonitorView: NSView {
        var owner: PickerKeyMonitor?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        deinit { removeMonitor() }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let owner, let window, event.window === window, window.isKeyWindow else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers ?? ""

            if flags == .command {
                if let digit = Int(chars), (1...9).contains(digit) {
                    return owner.onPinShortcut(digit)
                }
                if chars.lowercased() == "f" {
                    owner.onFocusSearch()
                    return true
                }
                return false
            }

            let responder = window.firstResponder
            let editor = responder as? NSTextView
            let inTextEditing = editor != nil
            let inSearch = (editor?.delegate is NSSearchField)

            if event.keyCode == 53, flags.isEmpty, !inSearch {
                return owner.onEscapeOutsideSearch()
            }
            if inTextEditing { return false }
            if flags.isEmpty || flags == .shift {
                if event.keyCode == 125 { owner.onArrow(+1); return true }
                if event.keyCode == 126 { owner.onArrow(-1); return true }
            }
            guard flags.subtracting(.shift).isEmpty,
                  let typed = event.characters, !typed.isEmpty,
                  typed.unicodeScalars.allSatisfy({ isPrintable($0) }),
                  typed != " " else { return false }
            owner.onTypeToSearch(typed)
            return true
        }

        private func isPrintable(_ s: Unicode.Scalar) -> Bool {
            if s.value < 0x20 || s.value == 0x7F { return false }
            if (0xF700...0xF8FF).contains(s.value) { return false }
            return true
        }
    }

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.owner = self
        return v
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.owner = self
    }
}

// MARK: - Highlighted text

enum PickerText {
    /// `text` with the characters at `indices - offset` drawn in gold.
    static func highlighted(
        _ text: String,
        indices: [Int],
        offset: Int,
        base: Color,
        emphasis: Font
    ) -> Text {
        let hits = Set(indices.map { $0 - offset })
        guard !hits.isEmpty, hits.contains(where: { $0 >= 0 && $0 < text.count }) else { return Text(text) }
        var attributed = AttributedString(text)
        var idx = attributed.startIndex
        var pos = 0
        while idx < attributed.endIndex {
            let next = attributed.index(afterCharacter: idx)
            if hits.contains(pos) {
                attributed[idx..<next].foregroundColor = BrandColors.goldSwiftUI
                attributed[idx..<next].font = emphasis
            } else {
                attributed[idx..<next].foregroundColor = base
            }
            idx = next
            pos += 1
        }
        return Text(attributed)
    }
}

// MARK: - Shared actions and context menu

/// Everything the row and tile context menus can do to one directory.
struct RecentActions {
    var isPinned: Bool
    var isOpen: Bool
    var isMissing: Bool
    var create: () -> Void
    var switchToOpen: () -> Void
    var togglePin: () -> Void
    var reveal: () -> Void
    var copyPath: () -> Void
    var remove: () -> Void
}

private struct RecentContextMenu: ViewModifier {
    let actions: RecentActions

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                actions.create()
            } label: {
                Text(String(localized: "createWorkspace.menu.create", defaultValue: "New workspace here"))
                Text("⏎")
            }
            .disabled(actions.isMissing)
            Button {
                actions.switchToOpen()
            } label: {
                Text(String(localized: "createWorkspace.menu.switch", defaultValue: "Switch to open workspace"))
                Text("⌥⏎")
            }
            .disabled(!actions.isOpen)
            Divider()
            Button {
                actions.togglePin()
            } label: {
                Text(actions.isPinned
                     ? String(localized: "createWorkspace.menu.unpin", defaultValue: "Unpin")
                     : String(localized: "createWorkspace.menu.pin", defaultValue: "Pin"))
            }
            Button {
                actions.reveal()
            } label: {
                Text(String(localized: "createWorkspace.menu.reveal", defaultValue: "Reveal in Finder"))
            }
            .disabled(actions.isMissing)
            Button {
                actions.copyPath()
            } label: {
                Text(String(localized: "createWorkspace.menu.copyPath", defaultValue: "Copy path"))
            }
            Divider()
            Button(role: .destructive) {
                actions.remove()
            } label: {
                Text(String(localized: "createWorkspace.menu.remove", defaultValue: "Remove from recents"))
            }
        }
    }
}

extension View {
    func recentContextMenu(_ actions: RecentActions) -> some View {
        modifier(RecentContextMenu(actions: actions))
    }
}

/// The green "already open in c11" dot.
struct OpenDot: View {
    var body: some View {
        Circle()
            .fill(Color(red: 0.50, green: 0.77, blue: 0.54))
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke(Color(red: 0.50, green: 0.77, blue: 0.54).opacity(0.25), lineWidth: 2))
    }
}

// MARK: - Recent row

/// One 28 pt row: open dot slot, name, parent path, time, count, pin star.
struct RecentRowView: View {
    /// A path-mode row is either the typed path ("Create in ...") or a
    /// directory under it; a normal row is a recent.
    enum Kind { case recent, typed, child }

    var kind: Kind = .recent
    /// False for a path-mode child that is not a recent (no time, count or pin).
    var hasHistory: Bool = true
    let recent: RecentDirectory
    /// Tilde-abbreviated absolute path.
    let displayPath: String
    let match: RecentMatch?
    let isSelected: Bool
    let isOpen: Bool
    let isMissing: Bool
    let isFlashing: Bool
    let actions: RecentActions
    let onClick: () -> Void
    let onDoubleClick: (_ optionHeld: Bool) -> Void
    let onTogglePin: () -> Void

    @State private var hovering = false

    static let height: CGFloat = 28

    private var name: String { RecentsPath.lastComponent(displayPath) }
    private var parent: String { RecentsPath.parent(displayPath) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                // Every row reserves the dot's slot so names stay aligned.
                ZStack {
                    if isOpen { OpenDot() }
                }
                .frame(width: 8, height: 8)

                nameText
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 260, alignment: .leading)
                    .layoutPriority(1)

                parentText
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(timeColumnText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(isMissing ? 0.7 : 0.55))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .trailing)

                Text(showsHistory ? "×\(recent.openCount)" : "")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.35))
                    .lineLimit(1)
                    .frame(width: 38, alignment: .trailing)
                    .help(recent.openCount == 1
                          ? String(localized: "createWorkspace.recents.openedOnce", defaultValue: "opened 1 time")
                          : String(
                            format: String(localized: "createWorkspace.recents.openedMany", defaultValue: "opened %d times"),
                            recent.openCount
                          ))
            }
            .opacity(isMissing ? 0.45 : 1)
            .strikethrough(isMissing, color: BrandColors.whiteSwiftUI.opacity(0.5))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityAction(named: Text(String(localized: "createWorkspace.a11y.open", defaultValue: "Open"))) {
                onDoubleClick(false)
            }

            if showsHistory {
            Button {
                onTogglePin()
            } label: {
                Image(systemName: recent.pinned ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(recent.pinned
                                     ? BrandColors.goldSwiftUI
                                     : BrandColors.whiteSwiftUI.opacity((hovering || isSelected) ? 0.55 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(
                format: recent.pinned
                    ? String(localized: "createWorkspace.a11y.unpin", defaultValue: "Unpin %@")
                    : String(localized: "createWorkspace.a11y.pin", defaultValue: "Pin %@"),
                name
            )))
            .help(recent.pinned
                  ? String(localized: "createWorkspace.recents.unpin", defaultValue: "Unpin")
                  : String(localized: "createWorkspace.recents.pin", defaultValue: "Pin"))
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .background(Rectangle().fill(rowBackground))
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(BrandColors.goldSwiftUI).frame(width: 2)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(BrandColors.ruleSwiftUI.opacity(0.7)).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(isMissing
              ? String(localized: "createWorkspace.recents.missingHelp", defaultValue: "This directory no longer exists")
              : recent.path)
        .gesture(
            TapGesture(count: 2).onEnded {
                onDoubleClick(NSEvent.modifierFlags.contains(.option))
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded { onClick() }
        )
        .recentContextMenu(actions)
    }

    private var accessibilityLabel: String {
        var parts = [name, parent]
        if isOpen { parts.append(String(localized: "createWorkspace.a11y.open.state", defaultValue: "open in c11")) }
        if isMissing { parts.append(String(localized: "createWorkspace.recents.missing", defaultValue: "missing")) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var rowBackground: Color {
        if isFlashing { return Color(red: 0.75, green: 0.31, blue: 0.30).opacity(0.30) }
        if isSelected { return BrandColors.goldFaintSwiftUI }
        if hovering { return BrandColors.whiteSwiftUI.opacity(0.035) }
        return .clear
    }

    private var showsHistory: Bool { kind == .recent || (kind == .child && hasHistory) }

    private var timeColumnText: String {
        if isMissing { return String(localized: "createWorkspace.recents.missing", defaultValue: "missing") }
        switch kind {
        case .typed:
            return String(localized: "createWorkspace.path.new", defaultValue: "new")
        case .child where !hasHistory:
            return ""
        default:
            return RecentsRelativeTime.label(
                since: recent.lastOpenedAt,
                justNow: String(localized: "createWorkspace.recents.justNow", defaultValue: "just now")
            )
        }
    }

    private var nameText: Text {
        if kind == .typed {
            return Text(String(
                format: String(localized: "createWorkspace.path.createIn", defaultValue: "⏎ Create in %@"),
                name
            ))
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(BrandColors.goldSwiftUI)
        }
        return PickerText.highlighted(
            name,
            indices: match?.indices ?? [],
            offset: max(0, displayPath.count - name.count),
            base: BrandColors.whiteSwiftUI,
            emphasis: .system(size: 13, weight: .bold)
        )
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(BrandColors.whiteSwiftUI)
    }

    private var parentText: Text {
        PickerText.highlighted(
            parent,
            indices: match?.indices ?? [],
            offset: 0,
            base: BrandColors.whiteSwiftUI.opacity(0.5),
            emphasis: .system(size: 11, weight: .bold, design: .monospaced)
        )
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(BrandColors.whiteSwiftUI.opacity(0.5))
    }
}

// MARK: - Pin tile

struct PinTileView: View {
    let path: String
    /// 0-based position in the pins order; 0...8 get a ⌘N badge.
    let index: Int
    let displayPath: String
    let isSelected: Bool
    let isOpen: Bool
    let isMissing: Bool
    let isFlashing: Bool
    let actions: RecentActions
    let onClick: () -> Void
    let onDoubleClick: (_ optionHeld: Bool) -> Void
    let onUnpin: () -> Void

    @State private var hovering = false

    static let width: CGFloat = 120
    static let height: CGFloat = 86
    private static let textWidth: CGFloat = 104

    private var name: String { RecentsPath.lastComponent(displayPath) }

    var body: some View {
        let nameLayout = PinTileNameLayout.layout(name: name, width: Self.textWidth)
        let parentLine = PinTileParentLine.fit(parentPath: RecentsPath.parent(displayPath), width: Self.textWidth)
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(BrandColors.goldFaintSwiftUI)
                      : AnyShapeStyle(LinearGradient(
                        colors: [Color(red: 0.185, green: 0.185, blue: 0.208), Color(red: 0.149, green: 0.149, blue: 0.169)],
                        startPoint: .top, endPoint: .bottom)))
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? BrandColors.goldSwiftUI
                                   : (hovering ? Color(white: 0.37) : Color(white: 0.25)),
                        lineWidth: 1)
            if isFlashing {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 0.75, green: 0.31, blue: 0.30).opacity(0.30))
            }

            VStack(spacing: 3) {
                VStack(spacing: 0) {
                    ForEach(Array(nameLayout.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: nameLayout.fontSize, weight: .semibold))
                            .foregroundStyle(BrandColors.whiteSwiftUI)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Text(parentLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.textWidth)
            }
            .padding(.top, 14)
            .strikethrough(isMissing, color: BrandColors.whiteSwiftUI.opacity(0.5))
            .opacity(isMissing ? 0.45 : 1)
            .frame(width: Self.width, height: Self.height)
            .accessibilityElement(children: .ignore)
        }
        .frame(width: Self.width, height: Self.height)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(BrandColors.goldSwiftUI)
                if isOpen { OpenDot() }
            }
            .padding(.top, 8)
            .padding(.leading, 10)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            // The badge and the × share one slot, so nothing shifts on hover.
            ZStack {
                if hovering {
                    Button(action: onUnpin) {
                        Text("×")
                            .font(.system(size: 13))
                            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.7))
                            .frame(width: 24, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(String(
                        format: String(localized: "createWorkspace.a11y.unpin", defaultValue: "Unpin %@"),
                        name
                    )))
                    .help(String(localized: "createWorkspace.recents.unpin", defaultValue: "Unpin"))
                } else if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.5))
                        .frame(width: 24, height: 16)
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 5)
            .padding(.trailing, 5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
        .help(isMissing
              ? path + " " + String(localized: "createWorkspace.tile.missingSuffix", defaultValue: "(no longer exists)")
              : path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(name + ", " + RecentsPath.parent(displayPath)))
        .accessibilityAction(named: Text(String(localized: "createWorkspace.a11y.open", defaultValue: "Open"))) {
            onDoubleClick(false)
        }
        .gesture(
            TapGesture(count: 2).onEnded {
                onDoubleClick(NSEvent.modifierFlags.contains(.option))
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded { onClick() }
        )
        .recentContextMenu(actions)
    }
}

// MARK: - Pin reorder

/// Live reorder while a pin tile is dragged over its neighbours.
struct PinReorderDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let pins: () -> [String]
    let move: (_ path: String, _ index: Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let to = pins().firstIndex(of: target) else { return }
        move(dragging, to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
