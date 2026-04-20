import SwiftUI

/// First tenant of the bottom status bar. Icon + badge only — no visible
/// text label (tooltip carries the affordance copy). Mirrors the binding
/// and click-handler pattern at `UpdateTitlebarAccessory.swift:1008` and
/// the `.safeHelp` shortcut-tooltip pattern at `NotificationsPage.swift:117`.
struct JumpToUnreadStatusBarButton: View {
    @EnvironmentObject private var notificationStore: TerminalNotificationStore

    private var display: StatusBarButtonDisplay {
        StatusBarButtonDisplay(unreadCount: notificationStore.unreadCount)
    }

    private var tooltipBase: String {
        String(
            localized: "notifications.jumpToLatestUnread",
            defaultValue: "Jump to Latest Unread"
        )
    }

    private var accessibilityLabel: String {
        String(
            localized: "statusBar.jumpToUnread.accessibility",
            defaultValue: "Jump to latest unread notification"
        )
    }

    var body: some View {
        let display = self.display
        return Button(action: jump) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 16, height: 16)

                if let badge = display.badgeText {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.accentColor)
                        )
                        .foregroundColor(.white)
                        .offset(x: 7, y: -5)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(!display.isEnabled)
        .opacity(display.isEnabled ? 1.0 : 0.45)
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
