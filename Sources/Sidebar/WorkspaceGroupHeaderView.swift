import AppKit
import SwiftUI

/// Rendering depends only on immutable values. Callbacks must resolve the current
/// group by ID when invoked; they must not capture member arrays or old pin state.
struct WorkspaceGroupHeaderView: View, Equatable {
    let group: WorkspaceGroup
    let summary: WorkspaceGroupHeaderSummary
    let isActive: Bool
    var scale: CGFloat = 1
    var horizontalPadding: CGFloat = 8
    var colorScheme: ColorScheme = .light
    var palette: [WorkspaceColorEntry] = WorkspaceColorSettings.defaultPalette
    /// One line beside compact workspace cards (C11H-221): the counts move up
    /// beside the name and the badge row goes.
    var compact: Bool = false
    /// The group's own Captain (C11H-299). Its mark sits in a fixed slot on the
    /// name row, always reserved, so a Captain arriving or leaving moves nothing
    /// and the badge row keeps its width at the narrowest sidebar.
    var captain: WorkspaceCaptainSummary = .unset
    /// The active theme's `[states]`, for the waiting count's colour.
    var states: ThemeStatePalette = .unset
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

    private enum Editor: String, Identifiable {
        case name, icon, error
        var id: String { rawValue }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group && lhs.summary == rhs.summary
            && lhs.isActive == rhs.isActive && lhs.scale == rhs.scale
            && lhs.horizontalPadding == rhs.horizontalPadding
            && lhs.colorScheme == rhs.colorScheme && lhs.palette == rhs.palette
            && lhs.compact == rhs.compact && lhs.captain == rhs.captain
            && lhs.states == rhs.states
    }

    static func height(scale: CGFloat = 1, compact: Bool = false) -> CGFloat { (compact ? 32 : 52) * scale }

    private var waitingTint: Color { Self.waitingTint(colorScheme: colorScheme, states: states) }

    /// The waiting count in the waiting colour for this slot, on the header's
    /// opaque surface: the theme's `[states]`, else c11's (C11H-344: white on
    /// dark, near-black on light).
    static func waitingTint(colorScheme: ColorScheme, states: ThemeStatePalette) -> Color {
        let hex = Workspace.resolvedSurfaceTabActivityColors(lightBackground: colorScheme == .light, states: states).waitingHex
        return Color(nsColor: hex.flatMap(NSColor.init(hex:)) ?? .labelColor)
    }

    private var tint: Color {
        if summary.flaggedCount > 0 {
            // Same attention violet as WorkspacePulseMark, including suppressed flags.
            return Color(nsColor: NSColor(srgbRed: 0x9D / 255, green: 0x8A / 255, blue: 0xD9 / 255, alpha: 1))
        }
        if let color = group.color,
           let tint = WorkspaceColorSettings.displayColor(hex: color, colorScheme: colorScheme) {
            return tint
        }
        return .secondary
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
        // Two fixed rows keep the full-size name useful in a narrow sidebar.
        // Every attention slot remains present at zero, during hover and at 99+.
        VStack(spacing: 2 * scale) {
            HStack(spacing: (compact ? 4 : 5) * scale) {
                Button { onToggleCollapse(group.id) } label: {
                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .frame(width: (compact ? 16 : 20) * scale, height: 24 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(collapseLabel))
                .accessibilityValue(Text(verbatim: group.name))
                .help(collapseLabel)

                SidebarIconGlyphView(glyph: SidebarIconGlyph.forGroupIcon(group.icon) ?? .symbol("folder.fill"),
                                     size: 13 * scale)
                    .foregroundColor(tint)
                    .frame(width: (compact ? 14 : 18) * scale, height: 24 * scale)
                    .accessibilityHidden(true)

                Button { onFocus(group.id) } label: {
                    Text(verbatim: group.name)
                        .font(.system(size: 13 * scale, weight: isActive ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 24 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(summaryLabel))
                .accessibilityHint(Text(summary.memberCount == 0
                    ? String(localized: "workspaceGroup.accessibility.empty", defaultValue: "Empty group. Add a workspace to focus it.")
                    : String(localized: "workspaceGroup.accessibility.focus", defaultValue: "Focus a workspace in this group.")))
                .help(group.name)

                if compact {
                    // One fixed attention slot keeps the name readable in a narrow
                    // sidebar: flags when any are up, else waiting.
                    if summary.flaggedCount > 0 {
                        badge("flag.fill", count: summary.flaggedCount, color: tint, width: 32,
                              label: String(localized: "workspaceGroup.flaggedCount", defaultValue: "\(summary.flaggedCount) flagged panels"))
                    } else {
                        badge("hourglass", count: summary.waitingCount, color: waitingTint, width: 32,
                              label: String(localized: "workspaceGroup.waitingCount", defaultValue: "\(summary.waitingCount) waiting panels"))
                    }
                }

                captainSlot

                if !compact || group.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9 * scale))
                    .foregroundColor(.secondary)
                    .opacity(group.isPinned ? 1 : 0)
                    .frame(width: 12 * scale, height: 24 * scale)
                    .accessibilityHidden(!group.isPinned)
                    .accessibilityLabel(Text(String(localized: "workspaceGroup.pinned", defaultValue: "Pinned group")))
                }

                Menu { menuContent } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: (compact ? 18 : 22) * scale, height: 24 * scale)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text(String(localized: "workspaceGroup.actions", defaultValue: "Group actions")))
                .accessibilityValue(Text(verbatim: group.name))
                .help(String(localized: "workspaceGroup.actions", defaultValue: "Group actions"))
            }

            if !compact {
            HStack(spacing: 3 * scale) {
                badge("square.stack", count: summary.memberCount, color: .secondary,
                      label: String(localized: "workspaceGroup.memberCount", defaultValue: "\(summary.memberCount) workspaces"))
                badge("flag.fill", count: summary.flaggedCount, color: tint,
                      label: String(localized: "workspaceGroup.flaggedCount", defaultValue: "\(summary.flaggedCount) flagged panels"))
                badge("hourglass", count: summary.waitingCount, color: waitingTint,
                      label: String(localized: "workspaceGroup.waitingCount", defaultValue: "\(summary.waitingCount) waiting panels"))
                badge("envelope.badge", count: summary.unreadCount, color: .accentColor,
                      label: String(localized: "workspaceGroup.unreadCount", defaultValue: "\(summary.unreadCount) unread notifications"))
                Spacer(minLength: 0)
            }
            .padding(.leading, 25 * scale)
            .frame(height: 18 * scale)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 4 * scale)
        .frame(height: Self.height(scale: scale, compact: compact))
        .background(RoundedRectangle(cornerRadius: 5 * scale)
            .fill(isActive ? Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.12) : Color.clear))
        // Semantic text needs an opaque matching surface even when the sidebar
        // material or terminal theme behind it remains dark in Light appearance.
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 5 * scale))
        .contentShape(Rectangle())
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

    /// One mark for the whole group: filled while one open panel holds the
    /// address, hollow when nobody does, a warning glyph for several holders.
    /// Fixed width and height in every state, transparent when unset; the
    /// holder's title and address are in the tooltip and accessibility text.
    private var captainSlot: some View {
        let description = captain.accessibilityDescription
        let color = Color(nsColor: .controlAccentColor)
        return Group {
            if captain.state == .ambiguous {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundColor(color)
            } else {
                WorkspaceCaptainHat()
                    .fill(captain.present ? color : Color.clear)
                    .overlay(WorkspaceCaptainHat().stroke(color, lineWidth: 1))
                    .frame(width: 12 * scale, height: 10 * scale)
            }
        }
        .frame(width: 14 * scale, height: 24 * scale)
        .opacity(captain.address == nil ? 0 : 1)
        .help(description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: description))
        .accessibilityHidden(captain.address == nil)
        .accessibilityIdentifier("workspace-group-captain-\(group.id.uuidString)")
    }

    private func badge(_ symbol: String, count: Int, color: Color, width: CGFloat = 37, label: String) -> some View {
        HStack(spacing: 3 * scale) {
            Image(systemName: symbol)
                .font(.system(size: 9 * scale))
                .frame(width: 12 * scale)
            Text(verbatim: count > 99
                 ? String(localized: "workspaceGroup.countOverflow", defaultValue: "99+") : String(count))
                .font(.system(size: 10 * scale, weight: .medium))
                .monospacedDigit()
                .frame(width: (width - 15) * scale, alignment: .leading)
        }
        .foregroundColor(count > 0 ? color : .secondary.opacity(0.65))
        .frame(width: width * scale, height: 18 * scale, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .help(label)
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
