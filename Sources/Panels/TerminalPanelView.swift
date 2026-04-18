import SwiftUI
import Foundation
import AppKit

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    // [TextBox] TextBox Input settings (plan §4.3)
    @AppStorage(TextBoxInputSettings.enabledKey)
    private var textBoxEnabled = TextBoxInputSettings.defaultEnabled
    @AppStorage(TextBoxInputSettings.enterToSendKey)
    private var textBoxEnterToSend = TextBoxInputSettings.defaultEnterToSend
    @AppStorage(TextBoxInputSettings.shortcutBehaviorKey)
    private var textBoxShortcutBehavior = TextBoxInputSettings.defaultShortcutBehavior.rawValue
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void

    /// Whether the TextBox should be mounted for this panel right now.
    /// Global setting AND per-panel flag both must be on.
    private var showTextBox: Bool {
        textBoxEnabled && panel.isTextBoxActive
    }

    /// Resolve the terminal type from SurfaceMetadataStore (set by
    /// AgentDetector). Returns `nil` until the detector has classified
    /// the surface; `TextBoxAppDetection` falls back to title regex in
    /// that case.
    private var terminalTypeFromMetadata: String? {
        let snapshot = SurfaceMetadataStore.shared.getMetadata(
            workspaceId: panel.workspaceId, surfaceId: panel.id
        )
        return snapshot.metadata[MetadataKey.terminalType] as? String
    }

    /// Font to use for the TextBox. Matches the active Ghostty config
    /// size when available; falls back to the system monospaced default.
    private var terminalFont: NSFont {
        NSFont.monospacedSystemFont(
            ofSize: GhosttyConfig.load().fontSize,
            weight: .regular
        )
    }

    var body: some View {
        // Layering contract: terminal find UI is mounted in GhosttySurfaceScrollView (AppKit portal layer)
        // via `searchState`. Rendering `SurfaceSearchOverlay` in this SwiftUI container can hide it.
        // The TextBox mounts BELOW the terminal view in a SwiftUI VStack — the search overlay stays in
        // the AppKit portal layer (unchanged) and is unaffected by this wrapper.
        VStack(spacing: 0) {
            GhosttyTerminalView(
                terminalSurface: panel.surface,
                isActive: isFocused,
                isVisibleInUI: isVisibleInUI,
                portalZPriority: portalPriority,
                showsInactiveOverlay: isSplit && !isFocused,
                showsUnreadNotificationRing: hasUnreadNotification && notificationPaneRingEnabled,
                inactiveOverlayColor: appearance.unfocusedOverlayNSColor,
                inactiveOverlayOpacity: appearance.unfocusedOverlayOpacity,
                searchState: panel.searchState,
                reattachToken: panel.viewReattachToken,
                onFocus: { _ in onFocus() },
                onTriggerFlash: onTriggerFlash
            )

            if showTextBox {
                TextBoxInputContainer(
                    text: $panel.textBoxContent,
                    enterToSend: textBoxEnterToSend,
                    surface: panel.surface,
                    terminalBackgroundColor: GhosttyApp.shared.defaultBackgroundColor
                        .withAlphaComponent(GhosttyApp.shared.defaultBackgroundOpacity),
                    terminalForegroundColor: GhosttyApp.shared.defaultForegroundColor,
                    terminalFont: terminalFont,
                    terminalTitle: panel.title,
                    terminalType: terminalTypeFromMetadata,
                    onInputTextViewCreated: { [weak panel] view in
                        panel?.inputTextView = view
                    }
                )
            }
        }
        // [TextBox] When the user flips "Enable Mode" on, force the panel's
        // runtime flag to match so the TextBox appears immediately without
        // needing the user to press Cmd+Option+B first.
        .onChange(of: textBoxEnabled) { newValue in
            if newValue {
                panel.isTextBoxActive = true
            }
        }
        // Keep the NSViewRepresentable identity stable across bonsplit structural updates.
        // This prevents transient teardown/recreate that can momentarily detach the hosted terminal view.
        .id(panel.id)
        .background(Color.clear)
    }
}

/// Shared appearance settings for panels
struct PanelAppearance {
    let dividerColor: Color
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        PanelAppearance(
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayNSColor: config.unfocusedSplitOverlayFill,
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity
        )
    }
}
