import SwiftUI

/// Module 3 — sidebar row chip.
///
/// Renders `AgentChip.iconAsset` (preferring bundled `AgentIcons/<type>` imageset,
/// falling back to the SF Symbol specified in `AgentChipResolver.sfSymbolFallback`)
/// plus an optional short label (`displayLabel`) next to the icon.
///
/// When `chip == nil`, renders nothing (zero-size view) — per spec, the chip is a
/// presentation-only hint and its absence must not perturb sidebar layout.
struct AgentChipBadge: View {
    let chip: AgentChip?
    let showsLabel: Bool
    let foreground: Color
    let secondary: Color

    var body: some View {
        if let chip {
            HStack(spacing: 4) {
                iconView(for: chip)
                    .frame(width: 14, height: 14)
                if showsLabel, let label = chip.displayLabel, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(for: chip))
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func iconView(for chip: AgentChip) -> some View {
        let assetName = chip.iconAsset
        let sfFallback = AgentChipResolver.sfSymbolFallback(forTerminalType: chip.terminalType)
        if NSImage(named: assetName) != nil {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(foreground)
        } else {
            Image(systemName: sfFallback)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(foreground)
        }
    }

    private func accessibilityLabel(for chip: AgentChip) -> String {
        if let label = chip.displayLabel, !label.isEmpty {
            return "\(chip.terminalType): \(label)"
        }
        return chip.terminalType
    }
}
