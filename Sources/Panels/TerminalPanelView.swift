import SwiftUI
import Foundation
import AppKit

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    @ObservedObject var paneInteractionRuntime: AreaInteractionRuntime
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage(NotificationAreaRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationAreaRingSettings.defaultEnabled
    @AppStorage(ThemeAppStorage.Keys.workspaceFrameEnabled, store: ThemeAppStorage.defaults)
    private var workspaceFrameEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    /// c11 (C11H-197): the hosting window's theme override.
    @Environment(\.c11WindowThemeName) private var windowThemeName
    // [TextBox] TextBox Input settings (plan §4.3)
    @AppStorage(TextBoxInputSettings.enterToSendKey)
    private var textBoxEnterToSend = TextBoxInputSettings.defaultEnterToSend
    @AppStorage(TextBoxInputSettings.shortcutBehaviorKey)
    private var textBoxShortcutBehavior = TextBoxInputSettings.defaultShortcutBehavior.rawValue
    let areaId: UUID
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
              let manager = app.workspaceManagerFor(workspaceId: panel.workspaceId) else {
            return nil
        }
        return manager.workspaces.first(where: { $0.id == panel.workspaceId })
    }

    private var portalWorkspaceFrameStyle: PortalWorkspaceFrameStyle? {
        guard workspaceFrameEnabled && themeManager.isEnabled else { return nil }

        let isWindowFocused = NSApp.keyWindow?.isKeyWindow ?? true
        let context = themeManager.makeContext(
            workspaceColor: owningWorkspace?.customColor,
            colorScheme: colorScheme,
            isWindowFocused: isWindowFocused,
            windowThemeName: windowThemeName
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
        let snapshot = PanelMetadataStore.shared.getMetadata(
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
            if let hostEnd = panel.visibleHCHostEnd {
                HCHostEndBanner(status: hostEnd,
                    resume: { owningWorkspace?.resumeHostEndedConversation(panelId: panel.id) },
                    dismiss: { panel.dismissHCHostEnd() })
            } else if let ended = panel.hcEndedNotice {
                HCEndedPanelBanner(notice: ended, starting: panel.hcStartingNewShell,
                    failure: panel.hcNewShellFailure,
                    startShell: { panel.startNewShellAfterEnd() },
                    // Its session is already over: Close needs no second question.
                    close: { _ = owningWorkspace?.closePanel(panel.id, force: true) })
            } else if let notice = panel.hcRestoreNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(notice.message).frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        panel.dismissHCRestoreNotice()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "terminal.restore.dismissNotice", defaultValue: "Dismiss recovery notice"))
                }
                .font(.callout)
                .padding(10)
                .background(.thinMaterial)
                .accessibilityIdentifier({
                    switch notice {
                    case .holderLost: return "hc-holder-loss-notice"
                    case .resourceExhausted: return "hc-resource-exhaustion-notice"
                    case .previousSessionEnded: return "hc-previous-session-ended-notice"
                    }
                }())
            }
            // C11H-434: an ended panel's banner already says nothing typed is
            // sent; "reconnects" would promise a terminal that is not coming.
            if let runtime = panel.hcSession, panel.hcEndedNotice == nil {
                HCTerminalInputNotice(runtime: runtime)
            }
            GhosttyTerminalView(
                terminalSurface: panel.surface,
                areaId: areaId,
                isActive: isFocused,
                isVisibleInUI: isVisibleInUI,
                portalZPriority: portalPriority,
                // C11H-434: an ended panel keeps its last screen, dimmed, so it
                // never reads as a live terminal.
                showsInactiveOverlay: (isSplit && !isFocused) || panel.hcEndedNotice != nil,
                showsUnreadNotificationRing: hasUnreadNotification && notificationPaneRingEnabled,
                inactiveOverlayColor: appearance.unfocusedOverlayNSColor,
                inactiveOverlayOpacity: panel.hcEndedNotice != nil
                    ? max(appearance.unfocusedOverlayOpacity, HCEndedPanelBanner.screenDimOpacity)
                    : appearance.unfocusedOverlayOpacity,
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
        // C11-25: drive the per-surface lifecycle (active ↔ throttled) from
        // the same `isVisibleInUI` flag the rest of the panel reads. Edge-
        // event only — onChange/onAppear, never per-keystroke.
        .onAppear {
            panel.applyVisibility(isVisibleInUI)
        }
        .onChange(of: isVisibleInUI) { newValue in
            panel.applyVisibility(newValue)
        }
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

/// Observes policy installation independently of terminal rendering updates.
private struct HCTerminalInputNotice: View {
    @ObservedObject var runtime: HCPanelSession
    var body: some View {
        if let policy = runtime.disconnectedInput {
            HCDisconnectedInputView(policy: policy)
        }
    }
}


/// C11H-196: what ended this panel's session, when (local time), and what c11
/// is doing about it. A conversation that was not resumed says why and offers
/// Resume conversation. Fixed layout: two text lines and the buttons, so the
/// banner never changes height as its phase advances.
struct HCHostEndBanner: View {
    let status: HCHostEndStatus
    let resume: () -> String?
    let dismiss: () -> Void
    @State private var refusal: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.offersResume ? "exclamationmark.triangle" : "arrow.clockwise")
            VStack(alignment: .leading, spacing: 2) {
                Text(status.headline).fontWeight(.semibold)
                Text(refusal ?? status.detail)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status.offersResume {
                Button(String(localized: "terminal.hostEnd.resumeButton", defaultValue: "Resume conversation")) {
                    refusal = resume()
                }
                .accessibilityIdentifier("hc-host-end-resume")
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "terminal.hostEnd.dismiss", defaultValue: "Dismiss"))
        }
        .font(.callout)
        .padding(10)
        .background(.thinMaterial)
        .accessibilityIdentifier("hc-host-end-notice")
        .onChange(of: status) { _ in refusal = nil }
    }
}

/// C11H-434: a panel kept after its terminal ended. The host-end banner's
/// layout: why and when it ended, what that means, and the two ways out.
/// Fixed layout, so starting a shell or a failure never changes its height.
struct HCEndedPanelBanner: View {
    /// How far the kept screen fades toward the terminal's background.
    static let screenDimOpacity = 0.5

    let notice: HCEndedPanelNotice
    let starting: Bool
    let failure: String?
    let startShell: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "stop.circle")
            VStack(alignment: .leading, spacing: 2) {
                // Wraps rather than truncates: the time is the part that matters.
                Text(notice.headline).fontWeight(.semibold)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hc-session-ended-headline")
                // A failure says what to do next: it gets room to say it in a narrow panel.
                Text(failure ?? notice.detail)
                    .lineLimit(failure == nil ? 2 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hc-session-ended-detail")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(HCEndedPanelNotice.startShellTitle) { startShell() }
                .disabled(starting)
                .accessibilityIdentifier("hc-session-ended-start-shell")
            Button(HCEndedPanelNotice.closeTitle) { close() }
                .accessibilityIdentifier("hc-session-ended-close")
        }
        .font(.callout)
        .padding(10)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hc-session-ended-notice")
    }
}
