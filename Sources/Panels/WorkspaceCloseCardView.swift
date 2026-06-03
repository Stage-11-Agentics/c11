import AppKit
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
/// every workspace-close prompt is destructive at workspace scale, and the
/// multi-close detail listing is already inlined into `content.message` by
/// `closeWorkspacesPlan`. If a non-destructive variant is ever needed, the
/// card should branch on `content.style` instead of growing a sibling view.
struct WorkspaceCloseCardView: View {
    let content: ConfirmContent
    @ObservedObject var runtime: WorkspaceCloseInteractionRuntime

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { /* swallow taps; explicit Cancel/Esc only */ }
                .accessibilityHidden(true)

            card
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
        }
    }

    @ViewBuilder
    private var card: some View {
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
        .padding(24)
        .frame(minWidth: 360, maxWidth: 480, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BrandColors.surfaceSwiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.85), lineWidth: 2)
                )
                .shadow(color: Color.red.opacity(0.45), radius: 20)
        )
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
