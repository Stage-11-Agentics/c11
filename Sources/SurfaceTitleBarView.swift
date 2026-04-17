import SwiftUI
import AppKit

// M7 — Surface title bar.
//
// Renders above every terminal surface (and, when mounted, browser/markdown).
// Shows a short title and an optional structured description; both ride on the
// per-surface metadata blob (`title` / `description` canonical keys owned by M2).
//
// The expand/collapse animation, description Markdown subset, and inline edit
// overlay are staged additively. The v1 mount renders a static single-line
// header fed from the M2 blob; the edit field is reserved for portal hosting in
// GhosttySurfaceScrollView (see spec: Layering constraint).

struct SurfaceTitleBarState: Equatable {
    var title: String?
    var description: String?
    var titleSource: MetadataSource?
    var descriptionSource: MetadataSource?
    var visible: Bool = true
    var collapsed: Bool = true
}

struct SurfaceTitleBarView: View {
    let state: SurfaceTitleBarState
    var onToggleCollapsed: () -> Void = {}

    var body: some View {
        if !state.visible {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                if !state.collapsed, let description = state.description, !description.isEmpty {
                    descriptionRow(description)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: NSColor.windowBackgroundColor)
                    .opacity(0.85)
            )
            .overlay(
                Rectangle()
                    .fill(Color(nsColor: NSColor.separatorColor))
                    .frame(height: 1),
                alignment: .bottom
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Button(action: onToggleCollapsed) {
                Image(systemName: state.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(state.description?.isEmpty ?? true)
            .accessibilityLabel(Text(
                String(localized: "titlebar.chevron",
                       defaultValue: "Toggle description")
            ))

            Text(state.title ?? String(localized: "titlebar.empty_title",
                                       defaultValue: "Untitled"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func descriptionRow(_ description: String) -> some View {
        Text(description)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 20)
            .padding(.top, 2)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let title = state.title, !title.isEmpty {
            parts.append(title)
        }
        if !state.collapsed, let description = state.description, !description.isEmpty {
            parts.append(description)
        }
        return parts.joined(separator: " — ")
    }
}
