import SwiftUI

/// First tenant of the bottom status bar. Mirrors the binding and
/// click-handler pattern at `UpdateTitlebarAccessory.swift:1008` and the
/// `.safeHelp` shortcut-tooltip pattern at `NotificationsPage.swift:117`.
struct JumpToUnreadStatusBarButton: View {
    @EnvironmentObject private var notificationStore: TerminalNotificationStore

    private var display: StatusBarButtonDisplay {
        StatusBarButtonDisplay(unreadCount: notificationStore.unreadCount)
    }

    private var tooltipBase: String {
        label
    }

    private var accessibilityLabel: String {
        String(
            localized: "statusBar.jumpToUnread.accessibility",
            defaultValue: "Jump to next unread notification"
        )
    }

    private var label: String {
        String(
            localized: "statusBar.nextNotification.title",
            defaultValue: "Go To Next Notification"
        )
    }

    var body: some View {
        let display = self.display
        return Button(action: jump) {
            HStack(spacing: 7) {
                Image(systemName: "bell")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)

                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                if let badge = display.badgeText {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(BrandColors.blackSwiftUI.opacity(0.18))
                        )
                        .foregroundColor(BrandColors.blackSwiftUI)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minHeight: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(cmuxAccentColor().opacity(display.isEnabled ? 1.0 : 0.18))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(cmuxAccentColor().opacity(display.isEnabled ? 0 : 0.5), lineWidth: 1)
            )
            .foregroundColor(display.isEnabled ? BrandColors.blackSwiftUI : .secondary)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!display.isEnabled)
        .opacity(display.isEnabled ? 1.0 : 0.72)
        .accessibilityIdentifier("statusBar.jumpToUnread.button")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(display.badgeText ?? "")
        .safeHelp(
            KeyboardShortcutSettings.Action.jumpToUnread.tooltip(tooltipBase)
        )
    }

    private func jump() {
        DispatchQueue.main.async {
            AppDelegate.shared?.jumpToLatestUnread()
        }
    }
}
