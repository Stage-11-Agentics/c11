import SwiftUI
import Foundation
import AppKit
import Bonsplit
import Combine

/// View that renders a Workspace's content using BonsplitView
struct WorkspaceContentView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var themeManager = ThemeManager.shared
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let workspacePortalPriority: Int
    let onThemeRefreshRequest: ((
        _ reason: String,
        _ backgroundEventId: UInt64?,
        _ backgroundSource: String?,
        _ notificationPayloadHex: String?
    ) -> Void)?
    @State private var config = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "stateInit")
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(ActivityMarkSettings.staticMarksKey)
    private var staticActivityMarks = ActivityMarkSettings.defaultStaticMarks
    @AppStorage(ThemeAppStorage.Keys.m1bWorkspaceContentViewContextMigrated, store: ThemeAppStorage.defaults)
    private var m1bWorkspaceContentViewContextMigrated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    /// c11 (C11H-197): the hosting window's theme override. The workspace keeps
    /// the last one it was shown with, for its AppKit-side bonsplit chrome.
    @Environment(\.c11WindowThemeName) private var windowThemeName
    @EnvironmentObject var notificationStore: TerminalNotificationStore

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.ignoresTopSafeArea(
            for: WorkspacePresentationModeSettings.mode(for: workspacePresentationMode)
        )
    }

    private var useThemeM1bWorkspaceContentViewContextPath: Bool {
        themeManager.themedPathLive(flag: m1bWorkspaceContentViewContextMigrated, windowThemeName: windowThemeName)
    }

    private var environmentThemeContext: ThemeContext {
        themeManager.makeContext(
            workspaceColor: workspace.customColor,
            colorScheme: colorScheme,
            isWindowFocused: NSApp.keyWindow?.isKeyWindow ?? true,
            windowThemeName: windowThemeName
        )
    }

    static func panelVisibleInUI(
        isWorkspaceVisible: Bool,
        isSelectedInPane: Bool,
        isFocused: Bool
    ) -> Bool {
        guard isWorkspaceVisible else { return false }
        // During pane/tab reparenting, Bonsplit can transiently report selected=false
        // for the currently focused panel. Keep focused content visible to avoid blank frames.
        return isSelectedInPane || isFocused
    }

    var body: some View {
        // C11H-238 meter: name what invalidated this body (stdout, meter runs only).
        let _ = GraphChurnMeter.printsChanges ? Self._printChanges() : ()
        let appearance = PanelAppearance.fromConfig(config)
        let isSplit = workspace.bonsplitController.allPaneIds.count > 1 ||
            workspace.panels.count > 1
        let areaFramePalette = AreaFramePalette.resolve(themeManager, context: environmentThemeContext)
        let captainTabIDs = Set(workspace.captainPanelIDs.compactMap { workspace.bonsplitTabIdFromTabId($0) })
        let captainFrameColor = themeManager.isEnabled
            ? themeManager.snapshot(for: environmentThemeContext).resolveStyleColor(.cardAccent, context: environmentThemeContext)
            : nil
        let captainFrameStyle = AreaFrameStroke(color: captainFrameColor ?? .controlAccentColor,
                                                thicknessPt: 1, cornerRadius: areaFramePalette?.cornerRadius ?? 0)

        // Inactive workspaces are kept alive in a ZStack (for state preservation) but their
        // AppKit-backed views can still intercept drags. Disable drop acceptance for them.
        let _ = { workspace.bonsplitController.isInteractive = isWorkspaceInputActive }()

        // Wire up file drop handling so bonsplit's PaneDragContainerView can forward
        // Finder file drops to the correct terminal panel.
        let _ = {
            workspace.bonsplitController.onFileDrop = { [weak workspace] urls, paneId in
                guard let workspace else { return false }
                // Find the focused panel in this pane and drop the files into it.
                guard let bonsplitTabId = workspace.bonsplitController.selectedTab(inPane: paneId)?.id,
                      let panelId = workspace.tabIdFromBonsplitTabId(bonsplitTabId),
                      let panel = workspace.panels[panelId] as? TerminalPanel else { return false }
                return panel.hostedView.handleDroppedURLs(urls)
            }
        }()

        let bonsplitView = BonsplitView(controller: workspace.bonsplitController) { bonsplitTab, paneId in
            // Content for each tab in bonsplit
            let _ = Self.debugPanelLookup(bonsplitTab: bonsplitTab, workspace: workspace)
            if let panel = workspace.panel(for: bonsplitTab.id) {
                let isFocused = isWorkspaceInputActive && workspace.focusedPanelId == panel.id
                let isSelectedInPane = workspace.bonsplitController.selectedTab(inPane: paneId)?.id == bonsplitTab.id
                let isVisibleInUI = Self.panelVisibleInUI(
                    isWorkspaceVisible: isWorkspaceVisible,
                    isSelectedInPane: isSelectedInPane,
                    isFocused: isFocused
                )
                let hasUnreadNotification = Workspace.shouldShowUnreadIndicator(
                    hasUnreadNotification: notificationStore.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: panel.id),
                    isManuallyUnread: workspace.manualUnreadPanelIds.contains(panel.id)
                )
                PanelContentView(
                    workspace: workspace,
                    panel: panel,
                    paneId: paneId,
                    isFocused: isFocused,
                    isSelectedInPane: isSelectedInPane,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: workspacePortalPriority,
                    isSplit: isSplit,
                    appearance: appearance,
                    hasUnreadNotification: hasUnreadNotification,
                    onFocus: {
                        // Keep bonsplit focus in sync with the AppKit first responder for the
                        // active workspace. This prevents divergence between the blue focused-tab
                        // indicator and where keyboard input/flash-focus actually lands.
                        guard isWorkspaceInputActive else { return }
                        guard workspace.panels[panel.id] != nil else { return }
                        workspace.focusPanel(panel.id, trigger: .terminalFirstResponder)
                    },
                    onRequestPanelFocus: {
                        guard isWorkspaceInputActive else { return }
                        guard workspace.panels[panel.id] != nil else { return }
                        workspace.focusPanel(panel.id)
                    },
                    onTriggerFlash: { workspace.triggerDebugFlash(panelId: panel.id) }
                )
                .onTapGesture {
                    workspace.bonsplitController.focusPane(paneId)
                }
            } else {
                // Fallback for tabs without panels (shouldn't happen normally)
                EmptyPanelView(workspace: workspace, paneId: paneId)
            }
        } emptyPane: { paneId in
            // Empty pane content
            EmptyPanelView(workspace: workspace, paneId: paneId)
                .onTapGesture {
                    workspace.bonsplitController.focusPane(paneId)
                }
        }
        .internalOnlyPanelDrag()
        // Inject a per-pane anchor view. The anchor itself draws nothing; it
        // reports its window-coord frame to the workspace's overlay controller
        // so the controller can mount the pane-close confirmation card in the
        // window's themeFrame (above the WindowTerminalPortal layer). Drawing
        // the overlay inside the SwiftUI tree leaves it stranded behind
        // portal-hosted terminals/browsers, which is why we route through an
        // AppKit overlay layer instead.
        //
        // The same slot carries each area's frame anchor (`[chrome.area]`), which the
        // portal overlays stroke above terminals and browsers, including captain
        // rings when the theme has no focus/waiting palette.
        .environment(\.paneOverlayBuilder, { paneId in
            AnyView(
                AreaInteractionOverlayHostView(
                    paneId: paneId,
                    controller: workspace.areaCloseOverlayController
                )
                .background {
                    if areaFramePalette != nil || !captainTabIDs.isEmpty {
                        AreaFrameAnchor(
                            palette: areaFramePalette,
                            paneId: paneId,
                            controller: workspace.bonsplitController,
                            isWorkspaceInputActive: isWorkspaceInputActive,
                            captainTabIDs: captainTabIDs,
                            captainStyle: captainFrameStyle
                        )
                        .equatable()
                    }
                }
            )
        })
        // Workspace-scoped close-confirmation anchor. Reports its window-coord
        // frame to `workspaceCloseOverlayController` so the AppKit-portal
        // overlay (themeFrame mount) covers exactly the workspace content
        // area, sidebar excluded. Hidden + non-hit-testing — purely a frame
        // publisher.
        .background(
            WorkspaceCloseOverlayHostView(
                controller: workspace.workspaceCloseOverlayController
            )
        )
        // Split zoom swaps Bonsplit between the full split tree and a single pane view.
        // Recreate the Bonsplit subtree on zoom enter/exit so stale pre-zoom pane chrome
        // cannot remain stacked above portal-hosted browser content.
        .id(splitZoomRenderIdentity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            syncBonsplitNotificationBadges()
            // c11 (C11H-197): a workspace that just appeared in a window (launch,
            // or moved here from another window) takes this window's theme
            // before its chrome is applied.
            workspace.windowThemeName = windowThemeName
            refreshGhosttyAppearanceConfig(reason: "onAppear")
        }
        .onChange(of: windowThemeName) { _, newValue in
            workspace.windowThemeName = newValue
            workspace.applyGhosttyChrome(from: config, reason: "windowThemeChanged")
        }
        .onChange(of: notificationStore.notifications) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: workspace.manualUnreadPanelIds) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: workspace.derivedActivityByPanel) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            GhosttyConfig.invalidateLoadCache()
            refreshGhosttyAppearanceConfig(reason: "ghosttyConfigDidReload")
        }
        .onChange(of: colorScheme) { oldValue, newValue in
            // Keep split overlay color/opacity in sync with light/dark theme transitions.
            refreshGhosttyAppearanceConfig(reason: "colorSchemeChanged:\(oldValue)->\(newValue)")
        }
        .onReceive(workspace.customColorDidChange) { _ in
            // Workspace color edits (sidebar color picker, CLI `workspace-color set`, theme
            // refresh) don't go through the Ghostty background pipeline, so without this
            // subscription the `$workspaceColor`-derived divider/frame/tab-indicator colors
            // would go stale until the next background-related event. The no-op guard in
            // `applyGhosttyChrome` keeps rapid color changes cheap.
            themeManager.invalidateForWorkspaceColorChange()
            workspace.applyGhosttyChrome(from: config, reason: "customColorDidChange")
        }
        .onReceive(themeManager.$active.dropFirst().receive(on: DispatchQueue.main)) { _ in
            // A theme load (`c11 themes set`, a user theme edit, a slot flip)
            // changes the strip's type, selection and state colours without any
            // Ghostty event. Keyed on the active theme, not the shared `version`,
            // which also bumps on every Ghostty background and workspace colour
            // change. `$active` publishes before the engine swaps its snapshot,
            // so the apply runs on the next main-queue turn, after it.
            workspace.applyGhosttyChrome(from: config, reason: "activeThemeChanged")
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { notification in
            let payloadHex = (notification.userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString() ?? "nil"
            let eventId = (notification.userInfo?[GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value
            let source = (notification.userInfo?[GhosttyNotificationKey.backgroundSource] as? String) ?? "nil"
            logTheme(
                "theme notification workspace=\(workspace.id.uuidString) event=\(eventId.map(String.init) ?? "nil") source=\(source) payload=\(payloadHex) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
            // Payload ordering can lag across rapid config/theme updates.
            // Resolve from GhosttyApp.shared.defaultBackgroundColor to keep tabs aligned
            // with Ghostty's current runtime theme.
            refreshGhosttyAppearanceConfig(
                reason: "ghosttyDefaultBackgroundDidChange",
                backgroundEventId: eventId,
                backgroundSource: source,
                notificationPayloadHex: payloadHex
            )
        }

        let content = Group {
            if isMinimalMode {
                bonsplitView
                    .ignoresSafeArea(.container, edges: .top)
            } else {
                bonsplitView
            }
        }
        // c11 owns mark policy. Bonsplit receives only the resolved generic
        // permission to subscribe: no user-default, accessibility, or
        // application-lifecycle semantics cross the package boundary.
        .environment(
            \.bonsplitActivityAnimationEnabled,
            ActivityMarkSettings.motionPermissions(
                inputActive: isWorkspaceInputActive, sceneActive: scenePhase == .active,
                reduceMotion: reduceMotion, staticMarks: staticActivityMarks
            ).defaultMotion
        )
        .environment(
            \.bonsplitExplicitActivityAnimationEnabled,
            ActivityMarkSettings.motionPermissions(
                inputActive: isWorkspaceInputActive, sceneActive: scenePhase == .active,
                reduceMotion: reduceMotion, staticMarks: staticActivityMarks
            ).explicitMotion
        )
        .overlay(
            WorkspaceFrame(
                workspace: workspace,
                themeManager: themeManager,
                isWorkspaceActive: isWorkspaceInputActive,
                isWindowFocused: NSApp.keyWindow?.isKeyWindow ?? true
            )
        )

        if useThemeM1bWorkspaceContentViewContextPath {
            content
                .environment(\.c11ThemeManager, themeManager)
                .environment(\.c11ThemeContext, environmentThemeContext)
        } else {
            content
        }
    }

    private func syncBonsplitNotificationBadges() {
        let unreadFromNotifications: Set<UUID> = Set(
            notificationStore.notifications
                .filter { $0.workspaceId == workspace.id && !$0.isRead }
                .compactMap { $0.surfaceId }
        )
        let manualUnread = workspace.manualUnreadPanelIds

        for paneId in workspace.bonsplitController.allPaneIds {
            for bonsplitTab in workspace.bonsplitController.tabs(inPane: paneId) {
                let panelId = workspace.tabIdFromBonsplitTabId(bonsplitTab.id)
                let expectedKind = panelId.flatMap { workspace.panelKind(panelId: $0) }
                let expectedPinned = panelId.map { workspace.isPanelPinned($0) } ?? false
                let expectedActivity = panelId.flatMap {
                    workspace.resolvedSurfacePanelActivityState(
                        panelId: $0,
                        hasExactSurfaceNotification: unreadFromNotifications.contains($0)
                    )
                }
                let expectedPresentation = panelId.flatMap {
                    workspace.resolvedSurfacePanelActivityPresentation(
                        panelId: $0,
                        activityState: expectedActivity
                    )
                }
                // Same notification rule as the sync path (signal-eligible unread), not
                // the raw-unread set the badge uses, so a suppressed agent's clock holds.
                if let panelId {
                    workspace.recordPanelSheetStatusTransition(
                        panelId: panelId,
                        activity: workspace.resolvedSurfacePanelActivityState(panelId: panelId)
                    )
                }
                let shouldShow = panelId.map { manualUnread.contains($0) } ?? false
                let kindUpdate: String?? = expectedKind.map { .some($0) }

                if bonsplitTab.showsNotificationBadge != shouldShow ||
                    bonsplitTab.activityState != expectedActivity ||
                    bonsplitTab.activityPresentation != expectedPresentation ||
                    bonsplitTab.isPinned != expectedPinned ||
                    (expectedKind != nil && bonsplitTab.kind != expectedKind) {
                    workspace.bonsplitController.updateTab(
                        bonsplitTab.id,
                        kind: kindUpdate,
                        showsNotificationBadge: shouldShow,
                        isPinned: expectedPinned,
                        activityState: .some(expectedActivity),
                        activityPresentation: .some(expectedPresentation)
                    )
                }
            }
        }
    }

    private var splitZoomRenderIdentity: String {
        workspace.bonsplitController.zoomedPaneId.map { "zoom:\($0.id.uuidString)" } ?? "unzoomed"
    }

    static func resolveGhosttyAppearanceConfig(
        reason: String = "unspecified",
        backgroundOverride: NSColor? = nil,
        loadConfig: () -> GhosttyConfig = { GhosttyConfig.load() },
        defaultBackground: () -> NSColor = { GhosttyApp.shared.defaultBackgroundColor },
        defaultBackgroundOpacity: () -> Double = { GhosttyApp.shared.defaultBackgroundOpacity }
    ) -> GhosttyConfig {
        var next = loadConfig()
        let loadedBackgroundHex = next.backgroundColor.hexString()
        let defaultBackgroundHex: String
        let resolvedBackground: NSColor

        if let backgroundOverride {
            resolvedBackground = backgroundOverride
            defaultBackgroundHex = "skipped"
        } else {
            let fallback = defaultBackground()
            resolvedBackground = fallback
            defaultBackgroundHex = fallback.hexString()
        }

        next.backgroundColor = resolvedBackground
        // Use the runtime opacity from the Ghostty engine, which may differ from the
        // file-level value parsed by GhosttyConfig.load().
        next.backgroundOpacity = defaultBackgroundOpacity()
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme resolve reason=\(reason) loadedBg=\(loadedBackgroundHex) overrideBg=\(backgroundOverride?.hexString() ?? "nil") defaultBg=\(defaultBackgroundHex) finalBg=\(next.backgroundColor.hexString()) opacity=\(String(format: "%.3f", next.backgroundOpacity)) theme=\(next.theme ?? "nil")"
            )
        }
        return next
    }

    private func refreshGhosttyAppearanceConfig(
        reason: String,
        backgroundOverride: NSColor? = nil,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil
    ) {
        let previousBackgroundHex = config.backgroundColor.hexString()
        let next = Self.resolveGhosttyAppearanceConfig(
            reason: reason,
            backgroundOverride: backgroundOverride
        )
        let eventLabel = backgroundEventId.map(String.init) ?? "nil"
        let sourceLabel = backgroundSource ?? "nil"
        let payloadLabel = notificationPayloadHex ?? "nil"
        let backgroundChanged = previousBackgroundHex != next.backgroundColor.hexString()
        let opacityChanged = abs(config.backgroundOpacity - next.backgroundOpacity) > 0.0001
        let shouldRequestTitlebarRefresh = backgroundChanged || opacityChanged || reason == "onAppear"
        logTheme(
            "theme refresh begin workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousBg=\(previousBackgroundHex) nextBg=\(next.backgroundColor.hexString()) overrideBg=\(backgroundOverride?.hexString() ?? "nil")"
        )
        withTransaction(Transaction(animation: nil)) {
            config = next
            if shouldRequestTitlebarRefresh {
                onThemeRefreshRequest?(
                    reason,
                    backgroundEventId,
                    backgroundSource,
                    notificationPayloadHex
                )
            }
        }
        if !shouldRequestTitlebarRefresh {
            logTheme(
                "theme refresh titlebar-skip workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) previousBg=\(previousBackgroundHex) nextBg=\(next.backgroundColor.hexString())"
            )
        }
        logTheme(
            "theme refresh config-applied workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) configBg=\(config.backgroundColor.hexString())"
        )
        let chromeReason =
            "refreshGhosttyAppearanceConfig:reason=\(reason):event=\(eventLabel):source=\(sourceLabel):payload=\(payloadLabel)"
        workspace.applyGhosttyChrome(from: next, reason: chromeReason)
        if let terminalPanel = workspace.focusedTerminalPanel {
            terminalPanel.applyWindowBackgroundIfActive()
            logTheme(
                "theme refresh terminal-applied workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) panel=\(workspace.focusedPanelId?.uuidString ?? "nil")"
            )
        } else {
            logTheme(
                "theme refresh terminal-skipped workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) focusedPanel=\(workspace.focusedPanelId?.uuidString ?? "nil")"
            )
        }
        logTheme(
            "theme refresh end workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) chromeBg=\(workspace.bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil")"
        )
    }

    private func logTheme(_ message: String) {
        guard GhosttyApp.shared.backgroundLogEnabled else { return }
        GhosttyApp.shared.logBackground(message)
    }
}

extension WorkspaceContentView {
    #if DEBUG
    static func debugPanelLookup(bonsplitTab: Bonsplit.Tab, workspace: Workspace) {
        let found = workspace.panel(for: bonsplitTab.id) != nil
        if !found {
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "[\(ts)] PANEL NOT FOUND for tabId=\(bonsplitTab.id) ws=\(workspace.id) panelCount=\(workspace.panels.count)\n"
            // c11's per-user folder, no-follow and owner checked (C11H-364 L21).
            C11UserRuntime.appendLog(Data(line.utf8), to: C11UserRuntime.logPath("cmux-panel-debug.log"))
        }
    }
    #else
    static func debugPanelLookup(bonsplitTab: Bonsplit.Tab, workspace: Workspace) {
        _ = bonsplitTab
        _ = workspace
    }
    #endif
}

/// One area's frame anchor (`AreaFrameAnchorView`). Its body reads the area's
/// focus and its tabs' marks from bonsplit, so it re-evaluates on a focus change or
/// a mark change (the same edges that repaint the activity marks), never per keystroke.
/// Only the selected workspace frames its areas: an outgoing workspace stays drawn
/// for a moment during a switch, and its rings must not show over the new one.
///
/// Equatable, and mounted `.equatable()`: the parent re-renders on every theme
/// version bump and builds a fresh palette, which must not re-run this body.
struct AreaFrameAnchor: View, Equatable {
    let palette: AreaFramePalette?
    let paneId: PaneID
    let controller: BonsplitController
    let isWorkspaceInputActive: Bool
    var captainTabIDs: Set<TabID> = []
    var captainStyle: AreaFrameStroke? = nil

    static func == (lhs: AreaFrameAnchor, rhs: AreaFrameAnchor) -> Bool {
        lhs.paneId == rhs.paneId
            && lhs.controller === rhs.controller
            && lhs.isWorkspaceInputActive == rhs.isWorkspaceInputActive
            && lhs.palette == rhs.palette
            && lhs.captainTabIDs == rhs.captainTabIDs
            && lhs.captainStyle == rhs.captainStyle
    }

    var body: some View {
        AreaFrameAnchorRepresentable(stroke: stroke, captainStroke: captainStroke)
            .equatable()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    var stroke: AreaFrameStroke? {
        guard isWorkspaceInputActive else { return nil }
        return palette?.stroke(
            isFocusedArea: controller.focusedPaneId == paneId,
            hasWaitingPanel: controller.tabs(inPane: paneId).contains { $0.activityState == .waiting }
        )
    }
    var captainStroke: AreaFrameStroke? {
        guard isWorkspaceInputActive, let selected = controller.selectedTab(inPane: paneId),
              captainTabIDs.contains(selected.id) else { return nil }
        return captainStyle
    }
}

/// Equatable on its stroke, so a title change in the area, which re-runs the
/// anchor's body, does not reach `updateNSView`.
struct AreaFrameAnchorRepresentable: NSViewRepresentable, Equatable {
    let stroke: AreaFrameStroke?
    var captainStroke: AreaFrameStroke? = nil

    func makeNSView(context: Context) -> AreaFrameAnchorView {
        let view = AreaFrameAnchorView(frame: .zero)
        view.stroke = stroke
        view.captainStroke = captainStroke
        return view
    }

    func updateNSView(_ nsView: AreaFrameAnchorView, context: Context) {
        nsView.stroke = stroke
        nsView.captainStroke = captainStroke
    }
}

/// View shown for empty panes
struct EmptyPanelView: View {
    @ObservedObject var workspace: Workspace
    let paneId: PaneID
    @AppStorage(KeyboardShortcutSettings.Action.newSurface.defaultsKey) private var newSurfaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.openBrowser.defaultsKey) private var openBrowserShortcutData = Data()

    private struct ShortcutHint: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.18), in: Capsule())
        }
    }

    private func focusPane() {
        workspace.bonsplitController.focusPane(paneId)
    }

    private func createTerminal() {
        #if DEBUG
        dlog("emptyPane.newTerminal pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        let workspace = workspace, paneId = paneId
        MachinePicker.ask(.terminal) { request in
            _ = workspace.newTerminalSurface(inPane: paneId, machine: request)
        }
    }

    private func createBrowser() {
        #if DEBUG
        dlog("emptyPane.newBrowser pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        PanelLineage.shared.withOrigin(.operator) {
            _ = workspace.newBrowserSurface(inPane: paneId)
        }
    }

    private var newSurfaceShortcut: StoredShortcut {
        decodeShortcut(from: newSurfaceShortcutData, fallback: KeyboardShortcutSettings.Action.newSurface.defaultShortcut)
    }

    private var openBrowserShortcut: StoredShortcut {
        decodeShortcut(from: openBrowserShortcutData, fallback: KeyboardShortcutSettings.Action.openBrowser.defaultShortcut)
    }

    private func decodeShortcut(from data: Data, fallback: StoredShortcut) -> StoredShortcut {
        guard !data.isEmpty,
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return fallback
        }
        return shortcut
    }

    @ViewBuilder
    private func emptyPaneActionButton(
        title: String,
        systemImage: String,
        shortcut: StoredShortcut,
        action: @escaping () -> Void
    ) -> some View {
        if let key = shortcut.keyEquivalent {
            Button(action: action) {
                HStack(spacing: 10) {
                    Label(title, systemImage: systemImage)
                    ShortcutHint(text: shortcut.displayString)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(action: action) {
                HStack(spacing: 10) {
                    Label(title, systemImage: systemImage)
                    ShortcutHint(text: shortcut.displayString)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text(String(localized: "workspace.emptyPane.title", defaultValue: "Empty Area"))
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                emptyPaneActionButton(
                    title: String(localized: "workspace.emptyPane.terminal", defaultValue: "Terminal"),
                    systemImage: "terminal.fill",
                    shortcut: newSurfaceShortcut,
                    action: createTerminal
                )

                emptyPaneActionButton(
                    title: String(localized: "workspace.emptyPane.browser", defaultValue: "Browser"),
                    systemImage: "globe",
                    shortcut: openBrowserShortcut,
                    action: createBrowser
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GhosttyBackgroundTheme.currentColor()))
#if DEBUG
        .onAppear {
            DebugUIEventCounters.emptyPanelAppearCount += 1
        }
#endif
    }
}

#if DEBUG
@MainActor
enum DebugUIEventCounters {
    static var emptyPanelAppearCount: Int = 0

    static func resetEmptyPanelAppearCount() {
        emptyPanelAppearCount = 0
    }
}
#endif
