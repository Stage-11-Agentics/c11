import AppKit
import SwiftUI

/// What a group header shows beside its name at a given width (C11H-410).
///
/// Other parts yield to the name one at a time, always in this order: the pin
/// marker, then the attention slot's glyph (its count stays), then a custom
/// icon, then the Captain mark. The two decorations (pin, glyph) yield while
/// the name is cut off and shorter than a comfortable width; the two identity
/// marks (icon, Captain) yield only to keep the name's floor. Either target is
/// the name's own width when that is less, so a short name costs nothing. The
/// chevron and the attention slot never yield; the slot also holds the actions
/// menu on hover. The decision reads only the width, the
/// scale, the name and what the operator configured (icon, Captain address,
/// pin), never a count, the selection or a Captain's presence, so nothing moves
/// when a flag goes up, the selection moves or a Captain arrives. The name has
/// one weight in every state for the same reason.
struct WorkspaceGroupHeaderLayout: Equatable {
    var showsPin: Bool
    var showsAttentionGlyph: Bool
    var showsIcon: Bool
    var showsCaptain: Bool
    /// The most the name may take, in points.
    var nameWidth: CGFloat
    /// The attention slot's width, in points.
    var slotWidth: CGFloat

    // Unscaled widths, in points at Chrome Scale 1.
    /// Width the name keeps before the icon or the Captain mark gives way:
    /// about eleven letters at the header's 11 pt.
    static let nameFloor: CGFloat = 72
    /// Width the name may claim from the pin and the count's glyph: about
    /// eighteen letters.
    static let nameComfort: CGFloat = 120
    /// The tab's leading inset and the chevron's hit target (its glyph plus the gap before the name).
    static let tabLeading: CGFloat = 2
    static let chevronWidth: CGFloat = 14
    /// Space after the name inside the tab.
    static let tabTrailing: CGFloat = 4
    static let iconWidth: CGFloat = 16
    /// The right-hand chip's inset on each side.
    static let chipInset: CGFloat = 2
    static let captainWidth: CGFloat = 14
    static let pinWidth: CGFloat = 10
    /// The count alone with its trailing inset ("99+" is about 20 pt at 10 pt
    /// type), and the menu on hover.
    static let slotCountWidth: CGFloat = 23
    /// What the flag or hourglass glyph and its gap add to the slot (the flag
    /// is about 9.6 pt per point of scale at 8 pt).
    static let slotGlyphWidth: CGFloat = 12

    /// - Parameters:
    ///   - width: the header's own width; `.infinity` when unknown.
    ///   - nameWidth: the width the whole name needs at this scale; `.infinity` when unknown.
    static func resolve(width: CGFloat, scale: CGFloat, nameWidth needed: CGFloat = .infinity,
                        hasIcon: Bool, hasCaptain: Bool, isPinned: Bool) -> Self {
        var layout = Self(showsPin: isPinned, showsAttentionGlyph: true, showsIcon: hasIcon, showsCaptain: hasCaptain,
                          nameWidth: 0, slotWidth: 0)
        func measure() {
            let slot = slotCountWidth + (layout.showsAttentionGlyph ? slotGlyphWidth : 0)
            let used = tabLeading + chevronWidth + tabTrailing + 2 * chipInset + slot
                + (layout.showsIcon ? iconWidth : 0)
                + (layout.showsCaptain ? captainWidth : 0)
                + (layout.showsPin ? pinWidth : 0)
            layout.slotWidth = slot * scale
            layout.nameWidth = max(0, width - used * scale)
        }
        measure()
        let yieldOrder: [(part: WritableKeyPath<Self, Bool>, target: CGFloat)] = [
            (\.showsPin, min(nameComfort * scale, needed)),
            (\.showsAttentionGlyph, min(nameComfort * scale, needed)),
            (\.showsIcon, min(nameFloor * scale, needed)),
            (\.showsCaptain, min(nameFloor * scale, needed)),
        ]
        for (part, target) in yieldOrder where layout.nameWidth < target && layout[keyPath: part] {
            layout[keyPath: part] = false
            measure()
        }
        return layout
    }
}

/// A group's header in the sidebar: a section label, not a card (C11H-410).
/// An opaque tab holds the chevron and the name, a hairline in the group's
/// colour runs to a small chip holding the Captain mark, the pin and the
/// attention count. The chips are opaque so the text keeps its contrast over
/// any sidebar backdrop (Sunset Mall, Outrun's gradient, the material).
///
/// Rendering depends only on immutable values. Callbacks must resolve the current
/// group by ID when invoked; they must not capture member arrays or old pin state.
struct WorkspaceGroupHeaderView: View, Equatable {
    let group: WorkspaceGroup
    let summary: WorkspaceGroupHeaderSummary
    let isActive: Bool
    var scale: CGFloat = 1
    var colorScheme: ColorScheme = .light
    var palette: [WorkspaceColorEntry] = WorkspaceColorSettings.defaultPalette
    /// Beside compact workspace cards (C11H-221): a shorter row.
    var compact: Bool = false
    /// The group's own Captain (C11H-299). Its mark has a fixed slot whenever
    /// the group declares an address, so a Captain arriving or leaving moves
    /// nothing; at the narrowest widths it is the last part to yield.
    var captain: WorkspaceCaptainSummary = .unset
    /// The active theme's `[states]`, for the waiting count's colour.
    var states: ThemeStatePalette = .unset
    /// The theme's sidebar values (fills, inks, rule); compared by stamp.
    var style: SidebarThemeStyle = .unset
    /// The header's own width, which decides what yields to the name.
    var availableWidth: CGFloat = .infinity
    let onToggleCollapse: (UUID) -> Void
    let onFocus: (UUID) -> Void
    let onRename: (UUID, String) throws -> Void
    let onSetColor: (UUID, String?) throws -> Void
    let onSetIcon: (UUID, String?) throws -> Void
    let onTogglePin: (UUID) -> Void
    let onUngroup: (UUID) -> Void
    let onDelete: (UUID) -> Void

    @State private var editor: Editor?
    @State private var editorFocusTarget: WorkspaceGroupEditorFocusTarget?
    @State private var actionError: String?
    /// Local to this header: the attention slot shows the actions menu while
    /// the pointer is over the header. The list never observes it.
    @State private var isHovered = false

    private enum Editor: String, Identifiable {
        case name, icon, error
        var id: String { rawValue }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group && lhs.summary == rhs.summary
            && lhs.isActive == rhs.isActive && lhs.scale == rhs.scale
            && lhs.colorScheme == rhs.colorScheme && lhs.palette == rhs.palette
            && lhs.compact == rhs.compact && lhs.captain == rhs.captain
            && lhs.states == rhs.states && lhs.style == rhs.style
            && lhs.availableWidth == rhs.availableWidth
    }

    static func height(scale: CGFloat = 1, compact: Bool = false) -> CGFloat { (compact ? 24 : 28) * scale }

    private var rowHeight: CGFloat { Self.height(scale: scale, compact: compact) }
    private var chipHeight: CGFloat { rowHeight - 4 * scale }
    private var chipShape: RoundedRectangle { RoundedRectangle(cornerRadius: min(style.cardRadius ?? 12, 4) * scale) }

    private var waitingTint: Color { Self.waitingTint(colorScheme: colorScheme, states: states) }

    /// The waiting count in the waiting colour for this slot, on the header's
    /// opaque surface: the theme's `[states]`, else c11's (C11H-344: white on
    /// dark, near-black on light).
    static func waitingTint(colorScheme: ColorScheme, states: ThemeStatePalette) -> Color {
        let hex = Workspace.resolvedSurfaceTabActivityColors(lightBackground: colorScheme == .light, states: states).waitingHex
        return Color(nsColor: hex.flatMap(NSColor.init(hex:)) ?? .labelColor)
    }

    /// Same attention violet as WorkspacePulseMark, including suppressed flags.
    private static let flagTint = Color(nsColor: NSColor(srgbRed: 0x9D / 255, green: 0x8A / 255, blue: 0xD9 / 255, alpha: 1))

    /// The chips' fill: the theme's card fill, else the card surface c11 draws.
    static func chipFill(style: SidebarThemeStyle, colorScheme: ColorScheme) -> Color {
        if let fill = style.cardFill { return fill }
        return colorScheme == .light
            ? Color(nsColor: NSColor(srgbRed: 0.96, green: 0.95, blue: 0.93, alpha: 1))
            : Color(nsColor: NSColor(srgbRed: 0.067, green: 0.075, blue: 0.09, alpha: 1))
    }

    /// The name's ink: full while the group holds the selected workspace,
    /// secondary otherwise. Explicit colours, since the chip is explicit too.
    private var nameInk: Color {
        if isActive {
            return style.cardText ?? (colorScheme == .light
                ? Color(nsColor: NSColor(white: 0.08, alpha: 1)) : Color(nsColor: NSColor(white: 0.92, alpha: 1)))
        }
        return style.cardTextSecondary ?? (colorScheme == .light
            ? Color(nsColor: NSColor(srgbRed: 0.33, green: 0.345, blue: 0.36, alpha: 1))
            : Color(nsColor: NSColor(srgbRed: 0.62, green: 0.645, blue: 0.68, alpha: 1)))
    }

    private var dimInk: Color {
        style.cardTextDim ?? (colorScheme == .light
            ? Color(nsColor: NSColor(white: 0.45, alpha: 1)) : Color(nsColor: NSColor(white: 0.5, alpha: 1)))
    }

    private var groupColor: Color? {
        group.color.flatMap { WorkspaceColorSettings.displayColor(hex: $0, colorScheme: colorScheme) }
    }

    private var ruleColor: Color {
        if let groupColor { return groupColor.opacity(0.7) }
        return style.cardRule ?? dimInk.opacity(0.45)
    }

    private var summaryLabel: String {
        String(localized: "workspaceGroup.accessibility.summary",
               defaultValue: "\(group.name): \(summary.memberCount) workspaces, \(summary.flaggedCount) flagged panels, \(summary.waitingCount) waiting panels, \(summary.unreadCount) unread notifications")
    }

    private var collapseLabel: String {
        group.isCollapsed
            ? String(localized: "workspaceGroup.expand", defaultValue: "Expand group")
            : String(localized: "workspaceGroup.collapse", defaultValue: "Collapse group")
    }

    private var deletionHelp: String {
        String(localized: "workspaceGroup.deleteHelp", defaultValue: "Remove the group and keep all member workspaces running, ungrouped.")
    }

    var body: some View {
        let icon = SidebarIconGlyph.forGroupIcon(group.icon)
        let layout = Self.layout(group: group, icon: icon, captain: captain, width: availableWidth, scale: scale)
        let fill = Self.chipFill(style: style, colorScheme: colorScheme)
        // A chip with nothing to show draws no fill and lets the rule run through
        // it to the edge. Its width stays reserved, so nothing moves when a count,
        // the pin or the menu appears.
        let chipShowsSomething = layout.showsCaptain || layout.showsPin || isHovered
            || summary.flaggedCount > 0 || summary.waitingCount > 0
        // One fixed-height row in both densities. The tab hugs the name; the
        // rule takes what is left and shrinks to nothing first, so at the
        // narrowest widths the two chips meet and read as one band.
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { onToggleCollapse(group.id) } label: {
                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9 * scale, weight: .bold))
                        .foregroundColor(groupColor ?? dimInk)
                        .frame(width: WorkspaceGroupHeaderLayout.chevronWidth * scale, height: chipHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(collapseLabel))
                .accessibilityValue(Text(verbatim: group.name))
                .help(collapseLabel)

                if layout.showsIcon, let icon {
                    SidebarIconGlyphView(glyph: icon, size: 11 * scale)
                        .foregroundColor(groupColor ?? nameInk)
                        .frame(width: WorkspaceGroupHeaderLayout.iconWidth * scale, height: chipHeight, alignment: .leading)
                        .accessibilityHidden(true)
                }

                Button { onFocus(group.id) } label: {
                    Text(verbatim: group.name)
                        // The exact font the layout measures.
                        .font(Font(NSFont.systemFont(ofSize: 11 * scale, weight: Self.nameWeight(isActive: isActive)) as CTFont))
                        .foregroundColor(nameInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The tab's width is decided here, not by the text's own
                        // width, so nothing about the name's state can move it.
                        .frame(width: Self.nameFrameWidth(group.name, scale: scale, isActive: isActive, layout: layout),
                               alignment: .leading)
                        .padding(.trailing, WorkspaceGroupHeaderLayout.tabTrailing * scale)
                        .frame(height: chipHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(summaryLabel))
                .accessibilityIdentifier("workspace-group-name-\(group.id.uuidString)")
                .accessibilityHint(Text(summary.memberCount == 0
                    ? String(localized: "workspaceGroup.accessibility.empty", defaultValue: "Empty group. Add a workspace to focus it.")
                    : String(localized: "workspaceGroup.accessibility.focus", defaultValue: "Focus a workspace in this group.")))
                .help(nameHelp(layout))
            }
            .padding(.leading, WorkspaceGroupHeaderLayout.tabLeading * scale)
            .background(fill, in: chipShape)
            .layoutPriority(1)

            Button { onFocus(group.id) } label: {
                Rectangle()
                    .fill(ruleColor)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity, minHeight: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            HStack(spacing: 0) {
                if layout.showsCaptain { captainSlot }
                if layout.showsPin {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8 * scale))
                        .foregroundColor(dimInk)
                        .frame(width: WorkspaceGroupHeaderLayout.pinWidth * scale, height: chipHeight)
                        .accessibilityLabel(Text(String(localized: "workspaceGroup.pinned", defaultValue: "Pinned group")))
                }
                attentionSlot(layout)
            }
            .padding(.horizontal, WorkspaceGroupHeaderLayout.chipInset * scale)
            .background {
                if chipShowsSomething {
                    chipShape.fill(fill)
                } else {
                    Rectangle().fill(ruleColor).frame(height: 1)
                }
            }
            .fixedSize()
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { menuContent }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-group-header-\(group.id.uuidString)")
        .popover(item: $editor, arrowEdge: .trailing) { editor in
            switch editor {
            case .name:
                WorkspaceGroupNameEditor(
                    initialName: group.name,
                    title: String(localized: "workspaceGroup.rename", defaultValue: "Rename Group"),
                    submitTitle: String(localized: "workspaceGroup.save", defaultValue: "Save"),
                    focusTarget: editorFocusTarget,
                    onSubmit: { try onRename(group.id, $0) },
                    onDismiss: { self.editor = nil }
                )
            case .icon:
                SidebarIconPicker(title: String(localized: "workspaceGroup.iconTitle", defaultValue: "Group Icon"),
                                  current: SidebarIconGlyph.forGroupIcon(group.icon),
                                  focusTarget: editorFocusTarget,
                                  onSubmit: { try onSetIcon(group.id, $0?.groupValue) },
                                  onDismiss: { self.editor = nil })
            case .error:
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: actionError ?? "")
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "workspaceGroup.dismiss", defaultValue: "Dismiss")) { self.editor = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
                .frame(width: 280)
                .onExitCommand { self.editor = nil }
                .onDisappear { editorFocusTarget?.restore() }
            }
        }
    }

    /// What the header shows at a width. It reads only what the operator
    /// configured: the icon, the Captain's address (never who holds it) and
    /// the pin.
    static func layout(group: WorkspaceGroup, icon: SidebarIconGlyph?, captain: WorkspaceCaptainSummary,
                       width: CGFloat, scale: CGFloat) -> WorkspaceGroupHeaderLayout {
        .resolve(width: width, scale: scale, nameWidth: nameWidth(group.name, scale: scale), hasIcon: icon != nil,
                 hasCaptain: captain.address != nil, isPinned: group.isPinned)
    }

    /// One weight in every state: a group holding the selection shows it by
    /// ink, never by weight, so moving the selection never widens the tab.
    static func nameWeight(isActive: Bool) -> NSFont.Weight { .semibold }

    /// The name's frame: its own width, or what the layout leaves it. Selected
    /// or not, the same width (C11H-410 review: a heavier weight moved the tab).
    static func nameFrameWidth(_ name: String, scale: CGFloat, isActive: Bool,
                               layout: WorkspaceGroupHeaderLayout) -> CGFloat {
        min(measure(name, scale: scale, weight: nameWeight(isActive: isActive)), layout.nameWidth)
    }

    /// The width the whole name needs at this scale.
    static func nameWidth(_ name: String, scale: CGFloat) -> CGFloat {
        measure(name, scale: scale, weight: nameWeight(isActive: false))
    }

    /// Measured names by scale, weight and text. Read and written on main
    /// (view bodies), and bounded: it starts over past 256 entries.
    private nonisolated(unsafe) static var nameWidthCache: [String: CGFloat] = [:]

    private static func measure(_ name: String, scale: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let key = "\(scale)\u{1F}\(weight.rawValue)\u{1F}\(name)"
        if let cached = nameWidthCache[key] { return cached }
        let font = NSFont.systemFont(ofSize: 11 * scale, weight: weight)
        let width = ceil((name as NSString).size(withAttributes: [.font: font]).width) + 1
        if nameWidthCache.count >= 256 { nameWidthCache.removeAll(keepingCapacity: true) }
        nameWidthCache[key] = width
        return width
    }

    /// The full name, and the Captain when its mark has yielded to the name.
    private func nameHelp(_ layout: WorkspaceGroupHeaderLayout) -> String {
        guard captain.address != nil, !layout.showsCaptain else { return group.name }
        return group.name + "\n" + captain.accessibilityDescription
    }

    /// Flags when any are up, else waiting, else empty; the slot keeps its
    /// width at zero. While the pointer is over the header it holds the
    /// actions menu instead, so the menu never takes width from the name.
    private func attentionSlot(_ layout: WorkspaceGroupHeaderLayout) -> some View {
        ZStack(alignment: .trailing) {
            attentionCount(showsGlyph: layout.showsAttentionGlyph)
                .opacity(isHovered ? 0 : 1)
            if isHovered {
                Menu { menuContent } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10 * scale, weight: .bold))
                        .frame(width: WorkspaceGroupHeaderLayout.slotCountWidth * scale, height: chipHeight)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text(String(localized: "workspaceGroup.actions", defaultValue: "Group actions")))
                .accessibilityValue(Text(verbatim: group.name))
                .accessibilityIdentifier("workspace-group-actions-\(group.id.uuidString)")
                .help(String(localized: "workspaceGroup.actions", defaultValue: "Group actions"))
            }
        }
        .frame(width: layout.slotWidth, height: chipHeight, alignment: .trailing)
    }

    @ViewBuilder
    private func attentionCount(showsGlyph: Bool) -> some View {
        let flagged = summary.flaggedCount > 0
        let count = flagged ? summary.flaggedCount : summary.waitingCount
        if count > 0 {
            let label = flagged
                ? String(localized: "workspaceGroup.flaggedCount", defaultValue: "\(summary.flaggedCount) flagged panels")
                : String(localized: "workspaceGroup.waitingCount", defaultValue: "\(summary.waitingCount) waiting panels")
            HStack(spacing: 2 * scale) {
                if showsGlyph {
                    Image(systemName: flagged ? "flag.fill" : "hourglass")
                        .font(.system(size: 8 * scale))
                }
                Text(verbatim: count > 99
                     ? String(localized: "workspaceGroup.countOverflow", defaultValue: "99+") : String(count))
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundColor(flagged ? Self.flagTint : waitingTint)
            .padding(.trailing, 2 * scale)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .help(label)
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    /// One mark for the whole group: filled while one open panel holds the
    /// address, hollow when nobody does, a warning glyph for several holders.
    /// Shown only when the group declares an address; fixed width and height
    /// in every state. The holder's title and address are in the tooltip and
    /// accessibility text.
    private var captainSlot: some View {
        let description = captain.accessibilityDescription
        let color = Color(nsColor: .controlAccentColor)
        return Group {
            if captain.state == .ambiguous {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(color)
            } else {
                WorkspaceCaptainHat()
                    .fill(captain.present ? color : Color.clear)
                    .overlay(WorkspaceCaptainHat().stroke(color, lineWidth: 1))
                    .frame(width: 11 * scale, height: 9 * scale)
            }
        }
        .frame(width: WorkspaceGroupHeaderLayout.captainWidth * scale, height: chipHeight)
        .help(description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: description))
        .accessibilityIdentifier("workspace-group-captain-\(group.id.uuidString)")
    }

    @ViewBuilder
    private var menuContent: some View {
        Button(String(localized: "workspaceGroup.rename", defaultValue: "Rename Group")) { beginEditing(.name) }
        Menu(String(localized: "workspaceGroup.color", defaultValue: "Color")) {
            Button(String(localized: "workspaceGroup.clearColor", defaultValue: "Clear Color")) {
                applyColor(nil)
            }
            Divider()
            ForEach(palette) { entry in
                Button { applyColor(entry.hex) } label: {
                    Label {
                        Text(verbatim: WorkspaceColorSettings.localizedColorName(entry.name))
                    } icon: {
                        Image(nsImage: colorSwatch(entry.hex))
                    }
                }
            }
        }
        Button(String(localized: "workspaceGroup.icon", defaultValue: "Icon…")) { beginEditing(.icon) }
        Button(group.isPinned
               ? String(localized: "workspaceGroup.unpin", defaultValue: "Unpin Group")
               : String(localized: "workspaceGroup.pin", defaultValue: "Pin Group")) { onTogglePin(group.id) }
        Divider()
        Button(String(localized: "workspaceGroup.ungroup", defaultValue: "Ungroup")) { onUngroup(group.id) }
            .help(deletionHelp)
            .accessibilityHint(Text(deletionHelp))
        Button(String(localized: "workspaceGroup.delete", defaultValue: "Delete Group")) { onDelete(group.id) }
            .help(deletionHelp)
            .accessibilityHint(Text(deletionHelp))
    }

    private func beginEditing(_ target: Editor) {
        editorFocusTarget = WorkspaceGroupEditorFocusTarget.capture()
        editor = target
    }

    private func applyColor(_ value: String?) {
        do { try onSetColor(group.id, value) }
        catch {
            actionError = error.localizedDescription
            beginEditing(.error)
        }
    }

    private func colorSwatch(_ hex: String) -> NSImage {
        let color = NSColor(hex: hex) ?? .gray
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// Weak native focus bookmark, local to an editor. Restoring never activates a
/// window, and a responder removed while editing is never reattached.
final class WorkspaceGroupEditorFocusTarget {
    private weak var window: NSWindow?
    private weak var responder: NSResponder?

    private init(window: NSWindow, responder: NSResponder?) {
        self.window = window
        self.responder = responder
    }

    static func capture() -> WorkspaceGroupEditorFocusTarget? {
        guard let window = NSApp.keyWindow else { return nil }
        return WorkspaceGroupEditorFocusTarget(window: window, responder: window.firstResponder)
    }

    func restore() {
        // Wait for the popover's window to relinquish key status. This never
        // raises a window that the operator switched away from while editing.
        DispatchQueue.main.async { [weak window = self.window, weak responder = self.responder] in
            guard let window, window.isKeyWindow, let responder else { return }
            if let view = responder as? NSView, view.window !== window { return }
            window.makeFirstResponder(responder)
        }
    }
}

/// Parent presents this in a popover for New Group or the header uses it to rename.
/// Capture focusTarget in the opening button callback when possible. onSubmit
/// throws to keep errors in the editor, and onDismiss only closes the popover.
struct WorkspaceGroupNameEditor: View {
    let initialName: String
    let title: String
    let submitTitle: String
    var focusTarget: WorkspaceGroupEditorFocusTarget? = nil
    let onSubmit: (String) throws -> Void
    let onDismiss: () -> Void

    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var capturedFocus: WorkspaceGroupEditorFocusTarget?
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title).font(.headline)
            TextField(String(localized: "workspaceGroup.name", defaultValue: "Group name"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { submit() }
            Text(verbatim: errorMessage ?? " ")
                .foregroundColor(.red)
                .font(.caption)
                .frame(height: 36, alignment: .topLeading)
                .accessibilityHidden(errorMessage == nil)
            HStack {
                Button(String(localized: "workspaceGroup.cancel", defaultValue: "Cancel"), action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(submitTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 290)
        .onAppear {
            capturedFocus = focusTarget ?? WorkspaceGroupEditorFocusTarget.capture()
            draft = initialName
            fieldFocused = false
        }
        .task {
            // Menu-driven popovers can appear before their field is attached.
            // Request focus after the presentation transaction, and abandon the
            // request if the operator dismisses the editor first.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            guard !Task.isCancelled else { return }
            fieldFocused = true
        }
        .onExitCommand(perform: onDismiss)
        .onDisappear {
            // SwiftUI may reuse the popover state on the next presentation.
            // Reset so onAppear requests a fresh field-focus transition.
            fieldFocused = false
            capturedFocus?.restore()
        }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        do {
            try onSubmit(trimmed)
            onDismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
