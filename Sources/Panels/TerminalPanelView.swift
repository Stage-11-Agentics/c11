import SwiftUI
import Foundation
import AppKit

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    @ObservedObject var paneInteractionRuntime: PaneInteractionRuntime
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    @AppStorage(ThemeAppStorage.Keys.workspaceFrameEnabled, store: ThemeAppStorage.defaults)
    private var workspaceFrameEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    // [TextBox] TextBox Input settings (plan §4.3)
    @AppStorage(TextBoxInputSettings.enterToSendKey)
    private var textBoxEnterToSend = TextBoxInputSettings.defaultEnterToSend
    @AppStorage(TextBoxInputSettings.shortcutBehaviorKey)
    private var textBoxShortcutBehavior = TextBoxInputSettings.defaultShortcutBehavior.rawValue
    let drawsPortalTopFrameEdge: Bool
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void

    /// Whether the TextBox should be mounted for this panel right now.
    /// Per-panel toggle is the only gate; Cmd+Option+B flips it.
    private var showTextBox: Bool {
        panel.isTextBoxActive
    }

    private var owningWorkspace: Workspace? {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId) else {
            return nil
        }
        return manager.tabs.first(where: { $0.id == panel.workspaceId })
    }

    private var portalWorkspaceFrameStyle: PortalWorkspaceFrameStyle? {
        guard workspaceFrameEnabled && themeManager.isEnabled else { return nil }

        let isWindowFocused = NSApp.keyWindow?.isKeyWindow ?? true
        let context = themeManager.makeContext(
            workspaceColor: owningWorkspace?.customColor,
            colorScheme: colorScheme,
            isWindowFocused: isWindowFocused
        )

        let strokeColor: NSColor = themeManager.resolve(.windowFrame_color, context: context) ?? .secondaryLabelColor
        let thickness: CGFloat = themeManager.resolve(.windowFrame_thicknessPt, context: context) ?? 1.5
        let inactiveOpacity: Double = themeManager.resolve(.windowFrame_inactiveOpacity, context: context) ?? 0.25
        let unfocusedOpacity: Double = themeManager.resolve(.windowFrame_unfocusedOpacity, context: context) ?? 0.6
        let opacity: Double
        if portalPriority < 2 {
            opacity = inactiveOpacity
        } else if !isWindowFocused {
            opacity = unfocusedOpacity
        } else {
            opacity = 1.0
        }

        return PortalWorkspaceFrameStyle(
            colorHex: strokeColor.hexString(includeAlpha: strokeColor.alphaComponent < 0.999),
            thicknessPt: thickness,
            opacity: opacity,
            edges: PortalWorkspaceFrameEdges(
                bottom: !showTextBox,
                top: drawsPortalTopFrameEdge
            )
        )
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
        // The pane-interaction overlay follows the same contract — mounted from the AppKit host
        // inside GhosttySurfaceScrollView (see `attachPaneInteraction(runtime:panelId:)`).
        // The TextBox mounts BELOW the terminal view in a SwiftUI VStack — the search overlay
        // stays in the AppKit portal layer (unchanged) and is unaffected by this wrapper.
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
                workspaceFrameStyle: portalWorkspaceFrameStyle,
                onFocus: { _ in onFocus() },
                onTriggerFlash: onTriggerFlash,
                paneInteractionRuntime: paneInteractionRuntime,
                paneInteractionPanelId: panel.id
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
