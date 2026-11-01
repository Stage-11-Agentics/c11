import AppKit
import Bonsplit
import Foundation
import SwiftUI

/// A pill-shaped button that displays update status and provides access to update actions.
struct UpdatePill: View {
    @ObservedObject var model: UpdateViewModel
    @State private var showPopover = false

    private let textFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    var body: some View {
        if model.showsPill {
            pillButton
                .popover(
                    isPresented: $showPopover,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    UpdatePopoverView(model: model)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    @ViewBuilder
    private var pillButton: some View {
        Button(action: {
            switch model.performPillAction() {
            case .checkDetectedUpdate:
                // Open the popover immediately so the user sees the install prompt
                // as soon as Sparkle's user-driver check completes — instead of having
                // to click the pill again after the background-detected version flips
                // to a checked-and-available state.
                showPopover = true
                AppDelegate.shared?.checkForUpdates(nil)
            case .togglePopover:
                showPopover.toggle()
            case .restart, .acknowledgeNotFound:
                break
            }
        }) {
            HStack(spacing: 6) {
                UpdateBadge(model: model)
                    .frame(width: 14, height: 14)

                Text(model.text)
                    .font(Font(textFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: textWidth, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(model.backgroundColor)
            )
            .foregroundColor(model.foregroundColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .safeHelp(model.text)
        .accessibilityLabel(model.text)
        .accessibilityIdentifier("UpdatePill")
    }

    private var textWidth: CGFloat? {
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        let size = (model.maxWidthText as NSString).size(withAttributes: attributes)
        return size.width
    }
}

/// Menu item that shows "Install Update and Relaunch" when an update is ready.
struct InstallUpdateMenuItem: View {
    @ObservedObject var model: UpdateViewModel

    var body: some View {
        if model.state.isInstallable {
            Button(String(localized: "update.installAndRelaunch", defaultValue: "Install Update and Relaunch")) {
                if !model.performRestartIfWaiting(source: "menu") {
                    model.state.confirm()
                }
            }
        }
    }
}
