import AppKit
import Bonsplit
import SwiftUI

/// Centered card for the workspace-scoped close-confirmation overlay.
///
/// The scrim is painted by the AppKit host (`WorkspaceCloseOverlayHost`) so
/// this view renders the card alone. Click-through outside the card is
/// swallowed by the host's hit-testing — explicit Cancel button or Esc only.
///
/// Visual treatment is intentionally hard-coded to "critical destructive"
/// (red icon, red border + shadow, red destructive button). The fields
/// `content.style`, `content.role`, and `content.detailLines` are part of
/// the shared `ConfirmContent` shape and are intentionally ignored here:
/// every workspace-close prompt is destructive at workspace scale. Under the
/// message, `content.workspaceInventory` lists every panel the close takes
/// down, so the operator sees how much work is at stake before confirming.
/// If a non-destructive variant is ever needed, the card should branch on
/// `content.style` instead of growing a sibling view.
struct WorkspaceCloseCardView: View {
    let content: ConfirmContent
    @ObservedObject var runtime: WorkspaceCloseInteractionRuntime

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { /* swallow taps; explicit Cancel/Esc only */ }
                    .accessibilityHidden(true)

                card(maxListHeight: Self.maxListHeight(available: proxy.size.height))
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// The panel list takes what the card's fixed parts leave of the area,
    /// up to a height that still reads as one card.
    static func maxListHeight(available: CGFloat) -> CGFloat {
        min(420, max(96, available - 280))
    }

    @ViewBuilder
    private func card(maxListHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.red)
                    .accessibilityHidden(true)
                Text(content.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(BrandColors.whiteSwiftUI)
            }

            if let message = content.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let inventory = content.workspaceInventory, inventory.panelCount > 0 {
                WorkspaceCloseInventoryView(inventory: inventory, maxListHeight: maxListHeight)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button(action: cancel) {
                    Text(content.cancelLabel)
                        .foregroundColor(BrandColors.whiteSwiftUI)
                        .frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .selectionBox(isActive: runtime.selection == .cancel)
                .accessibilityAddTraits(runtime.selection == .cancel ? .isSelected : [])
                .accessibilityIdentifier("WorkspaceCloseOverlay.cancel")

                Button(role: .destructive, action: confirm) {
                    Text(content.confirmLabel)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(BrandColors.whiteSwiftUI)
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .selectionBox(isActive: runtime.selection == .confirm)
                .accessibilityAddTraits(runtime.selection == .confirm ? .isSelected : [])
                .accessibilityIdentifier("WorkspaceCloseOverlay.confirm")
            }
        }
        // The card is as tall as its content; the panel list caps itself.
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(
            minWidth: 360,
            maxWidth: content.workspaceInventory == nil ? 480 : 560,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BrandColors.surfaceSwiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.85), lineWidth: 2)
                )
                .shadow(color: Color.red.opacity(0.45), radius: 20)
        )
        // Keeps the card off the edges of a narrow area.
        .padding(16)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("WorkspaceCloseOverlay.card")
    }

    private func confirm() {
        runtime.accept(ifInteractionId: content.id)
    }

    private func cancel() {
        runtime.cancel(ifInteractionId: content.id)
    }
}

private extension View {
    /// White rectangular outline around the currently-selected button. Mirrors
    /// `PaneInteractionCardView.selectionBox` so workspace-close and pane-close
    /// share the same focus-ring visual.
    @ViewBuilder
    func selectionBox(isActive: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white, lineWidth: isActive ? 2 : 0)
                .padding(-3)
                .animation(.easeInOut(duration: 0.12), value: isActive)
        )
    }
}

// MARK: - Inventory

/// Every panel a workspace close will take down, grouped by workspace and in
/// sidebar order. Each row reuses the panel sheet's detail, so the card names
/// a panel exactly as the sheet does: number, title, `Harness · model` or
/// kind, live subtitle, and state.
public struct WorkspaceCloseInventory {
    struct Row: Identifiable {
        let id: UUID
        let ordinal: Int?
        let title: String
        /// `Harness · model` for an agent, else Terminal / Browser / Markdown.
        let kindLabel: String
        /// The model-family tint; set only for agents.
        let agentTintHex: String?
        let subtitle: String?
        let status: BonsplitTabDetail.StatusKind?

        var isAgent: Bool { agentTintHex != nil }
    }

    struct Group: Identifiable {
        let id: UUID
        let title: String
        let rows: [Row]
    }

    let groups: [Group]

    init(groups: [Group]) {
        self.groups = groups
    }

    @MainActor
    init(workspaces: [Workspace]) {
        let showOrdinals = PanelOrdinalDisplaySettings.showsSurfaceIds()
        self.groups = workspaces.map { workspace in
            Group(
                id: workspace.id,
                title: Self.displayTitle(workspace.title),
                rows: workspace.sidebarOrderedPanelIds().compactMap { panelId in
                    guard let detail = workspace.panelSheetDetail(panelId: panelId) else { return nil }
                    return Row(
                        id: panelId,
                        ordinal: showOrdinals
                            ? TerminalController.shared.surfaceOrdinal(forSurfaceUUID: panelId)
                            : nil,
                        title: detail.title ?? String(
                            localized: "dialog.closeWorkspace.inventory.untitled",
                            defaultValue: "Untitled"
                        ),
                        kindLabel: detail.agentLabel ?? detail.typeLabel ?? "",
                        agentTintHex: detail.agentTintHex,
                        subtitle: detail.subtitle,
                        // A flag on a panel with no tracked activity (a plain
                        // terminal) still has to show: it is work the operator
                        // was asked to look at.
                        status: detail.status?.kind
                            ?? (workspace.attentionSnapshot(panelId: panelId).isFlagged ? .flagged : nil)
                    )
                }
            )
        }
    }

    var panelCount: Int { groups.reduce(0) { $0 + $1.rows.count } }
    var agentCount: Int { groups.reduce(0) { $0 + $1.rows.filter(\.isAgent).count } }

    func count(_ kind: BonsplitTabDetail.StatusKind) -> Int {
        groups.reduce(0) { $0 + $1.rows.filter { $0.status == kind }.count }
    }

    /// `12 panels · 4 agents`: the scale of what the close takes down.
    var scaleSummary: String {
        let panels = panelCount == 1
            ? String(localized: "dialog.closeWorkspace.inventory.onePanel", defaultValue: "1 panel")
            : String(
                format: String(localized: "dialog.closeWorkspace.inventory.panels", defaultValue: "%lld panels"),
                locale: .current,
                Int64(panelCount)
            )
        guard agentCount > 0 else { return panels }
        let agents = agentCount == 1
            ? String(localized: "dialog.closeWorkspace.inventory.oneAgent", defaultValue: "1 agent")
            : String(
                format: String(localized: "dialog.closeWorkspace.inventory.agents", defaultValue: "%lld agents"),
                locale: .current,
                Int64(agentCount)
            )
        return "\(panels) · \(agents)"
    }

    /// The live states worth stopping for, in the order the operator cares:
    /// flagged, waiting on them, working.
    var liveStateCounts: [(kind: BonsplitTabDetail.StatusKind, count: Int)] {
        let order: [BonsplitTabDetail.StatusKind] = [.flagged, .waiting, .working]
        return order.compactMap { kind in
            let n = count(kind)
            return n > 0 ? (kind, n) : nil
        }
    }

    static func statusWord(_ kind: BonsplitTabDetail.StatusKind) -> String {
        switch kind {
        case .working:
            return String(localized: "dialog.closeWorkspace.inventory.status.working", defaultValue: "working")
        case .waiting:
            return String(localized: "dialog.closeWorkspace.inventory.status.waiting", defaultValue: "waiting")
        case .flagged:
            return String(localized: "dialog.closeWorkspace.inventory.status.flagged", defaultValue: "flagged")
        case .idle:
            return String(localized: "dialog.closeWorkspace.inventory.status.idle", defaultValue: "idle")
        case .cold:
            return String(localized: "dialog.closeWorkspace.inventory.status.cold", defaultValue: "cold")
        }
    }

    /// `2 working`, `1 waiting`.
    static func stateCount(_ kind: BonsplitTabDetail.StatusKind, _ count: Int) -> String {
        String(
            format: String(localized: "dialog.closeWorkspace.inventory.stateCount", defaultValue: "%1$lld %2$@"),
            locale: .current,
            Int64(count),
            statusWord(kind)
        )
    }

    private static func displayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty { return collapsed }
        return String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
    }
}

/// The card's panel list: a scale line, then one two-line row per panel
/// (grouped under workspace headers when more than one workspace closes).
/// Scrolls once it outgrows `maxListHeight`.
struct WorkspaceCloseInventoryView: View {
    let inventory: WorkspaceCloseInventory
    let maxListHeight: CGFloat
    /// The list's measured height; before the first measure, an estimate from
    /// the row count so the card opens at (nearly) its final size.
    @State private var measuredListHeight: CGFloat?

    private static let amber = Color(red: 0xe0 / 255, green: 0xa0 / 255, blue: 0x30 / 255)
    private static let violet = Color(red: 0x9d / 255, green: 0x8a / 255, blue: 0xd9 / 255)
    private static let dim = Color(red: 0x9a / 255, green: 0x9c / 255, blue: 0xa3 / 255)
    private static let faint = Color(red: 0x74 / 255, green: 0x77 / 255, blue: 0x7f / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            ScrollView(.vertical) {
                list.background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .frame(height: min(measuredListHeight ?? estimatedListHeight, maxListHeight))
            .onPreferenceChange(ListHeightKey.self) { measuredListHeight = $0 }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .accessibilityIdentifier("WorkspaceCloseOverlay.inventory")
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(inventory.scaleSummary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)
            Spacer(minLength: 0)
            ForEach(inventory.liveStateCounts, id: \.kind) { entry in
                Text(WorkspaceCloseInventory.stateCount(entry.kind, entry.count))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Self.statusColor(entry.kind))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(inventory.groups.enumerated()), id: \.element.id) { index, group in
                if inventory.groups.count > 1 {
                    groupHeader(group, isFirst: index == 0)
                }
                ForEach(group.rows) { row in
                    rowView(row)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var estimatedListHeight: CGFloat {
        let headers = inventory.groups.count > 1 ? inventory.groups.count : 0
        return CGFloat(inventory.panelCount) * 36 + CGFloat(headers) * 24 + 12
    }

    private struct ListHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private var showsOrdinals: Bool {
        inventory.groups.contains { $0.rows.contains { $0.ordinal != nil } }
    }

    private func groupHeader(_ group: WorkspaceCloseInventory.Group, isFirst: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(group.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: "\(group.rows.count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Self.faint)
        }
        .padding(.horizontal, 10)
        .padding(.top, isFirst ? 2 : 10)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }

    private func rowView(_ row: WorkspaceCloseInventory.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showsOrdinals {
                Text(verbatim: row.ordinal.map(String.init) ?? "")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(BrandColors.goldSwiftUI)
                    .frame(width: 30, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(BrandColors.whiteSwiftUI)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let status = row.status {
                        Text(WorkspaceCloseInventory.statusWord(status))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Self.statusColor(status))
                            .fixedSize()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(row.kindLabel)
                        .foregroundStyle(row.agentTintHex.flatMap(Self.color(hex:)) ?? Self.dim)
                        .fixedSize()
                    if let subtitle = row.subtitle, !subtitle.isEmpty {
                        Text(verbatim: " · \(subtitle)")
                            .foregroundStyle(Self.faint)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private static func statusColor(_ kind: BonsplitTabDetail.StatusKind) -> Color {
        switch kind {
        case .working: return BrandColors.whiteSwiftUI
        case .waiting: return amber
        case .flagged: return violet
        case .idle, .cold: return faint
        }
    }

    private static func color(hex: String) -> Color? {
        NSColor(hex: hex).map { Color(nsColor: $0) }
    }
}
