import SwiftUI
import Foundation
import Bonsplit

/// View that renders the appropriate panel view based on panel type
struct TabContentView: View {
    @ObservedObject var workspace: Workspace
    let panel: any TabContent
    let paneId: PaneID
    let isFocused: Bool
    let isSelectedInPane: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: TabAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onRequestTabFocus: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            let titleBarState = workspace.tabTitleBarState(panelId: panel.id)
            if titleBarState.rendersBar {
                TabTitleBarView(
                    state: titleBarState,
                    onToggleCollapsed: { workspace.toggleSurfaceTitleBarCollapsed(panelId: panel.id) }
                )
            }
            contentView
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch panel.panelType {
        case .terminal:
            if let terminalTab = panel as? TerminalTab {
                TerminalTabView(
                    panel: terminalTab,
                    paneInteractionRuntime: workspace.paneInteractionRuntime,
                    areaId: paneId.id,
                    drawsPortalTopFrameEdge: !workspace.tabTitleBarState(panelId: terminalTab.id).rendersBar,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    isSplit: isSplit,
                    appearance: appearance,
                    hasUnreadNotification: hasUnreadNotification,
                    onFocus: onFocus,
                    onTriggerFlash: onTriggerFlash
                )
            }
        case .browser:
            if let browserTab = panel as? BrowserTab {
                BrowserTabView(
                    panel: browserTab,
                    paneInteractionRuntime: workspace.paneInteractionRuntime,
                    paneId: paneId,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onRequestTabFocus: onRequestTabFocus
                )
            }
        case .markdown:
            if let markdownTab = panel as? MarkdownTab {
                MarkdownTabView(
                    panel: markdownTab,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onRequestTabFocus: onRequestTabFocus,
                    paneInteractionRuntime: workspace.paneInteractionRuntime
                )
            }
        }
    }
}
