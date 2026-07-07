import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// v2 dispatch slice for the `pane.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchPane(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "pane.list":
            return v2Result(id: id, self.v2PaneList(params: params))
        case "pane.focus":
            return v2Result(id: id, self.v2PaneFocus(params: params))
        case "pane.surfaces":
            return v2Result(id: id, self.v2PaneSurfaces(params: params))
        case "pane.create":
            return v2Result(id: id, self.v2PaneCreate(params: params))
        case "pane.resize":
            return v2Result(id: id, self.v2PaneResize(params: params))
        case "pane.swap":
            return v2Result(id: id, self.v2PaneSwap(params: params))
        case "pane.break":
            return v2Result(id: id, self.v2PaneBreak(params: params))
        case "pane.join":
            return v2Result(id: id, self.v2PaneJoin(params: params))
        case "pane.last":
            return v2Result(id: id, self.v2PaneLast(params: params))
        case "pane.confirm":
            return v2Result(id: id, self.v2PaneConfirm(params: params))
        case "pane.set_metadata":
            return v2Result(id: id, self.v2PaneSetMetadata(params: params))
        case "pane.get_metadata":
            return v2Result(id: id, self.v2PaneGetMetadata(params: params))
        case "pane.clear_metadata":
            return v2Result(id: id, self.v2PaneClearMetadata(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private func v2PaneList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            let focusedPaneId = ws.bonsplitController.focusedPaneId
            let panes: [[String: Any]] = ws.bonsplitController.allPaneIds.enumerated().map { index, paneId in
                let tabs = ws.bonsplitController.tabs(inPane: paneId)
                let surfaceUUIDs: [UUID] = tabs.compactMap { ws.panelIdFromSurfaceId($0.id) }
                let selectedTab = ws.bonsplitController.selectedTab(inPane: paneId)
                let selectedSurfaceUUID = selectedTab.flatMap { ws.panelIdFromSurfaceId($0.id) }
                return [
                    "id": paneId.id.uuidString,
                    "ref": v2Ref(kind: .pane, uuid: paneId.id),
                    "index": index,
                    "focused": paneId == focusedPaneId,
                    "surface_ids": surfaceUUIDs.map { $0.uuidString },
                    "surface_refs": surfaceUUIDs.map { v2Ref(kind: .surface, uuid: $0) },
                    "selected_surface_id": v2OrNull(selectedSurfaceUUID?.uuidString),
                    "selected_surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceUUID),
                    "surface_count": surfaceUUIDs.count
                ]
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "panes": panes,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    private func v2PaneFocus(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let paneUUID = v2UUID(params, "pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid pane_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let paneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
                return
            }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            if tabManager.selectedTabId != ws.id {
                tabManager.selectWorkspace(ws)
            }
            ws.bonsplitController.focusPane(paneId)
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok(["window_id": v2OrNull(windowId?.uuidString), "window_ref": v2Ref(kind: .window, uuid: windowId), "workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "pane_id": paneId.id.uuidString, "pane_ref": v2Ref(kind: .pane, uuid: paneId.id)])
        }
        return result
    }

    private func v2PaneSurfaces(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            let paneUUID = v2UUID(params, "pane_id")
            let paneId: PaneID? = {
                if let paneUUID {
                    return ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID })
                }
                return ws.bonsplitController.focusedPaneId
            }()
            guard let paneId else { return }

            let selectedTab = ws.bonsplitController.selectedTab(inPane: paneId)
            let tabs = ws.bonsplitController.tabs(inPane: paneId)

            let surfaces: [[String: Any]] = tabs.enumerated().map { index, tab in
                let panelId = ws.panelIdFromSurfaceId(tab.id)
                let panel = panelId.flatMap { ws.panels[$0] }
                return [
                    "id": v2OrNull(panelId?.uuidString),
                    "ref": v2Ref(kind: .surface, uuid: panelId),
                    "index": index,
                    "title": tab.title,
                    "type": v2OrNull(panel?.panelType.rawValue),
                    "selected": tab.id == selectedTab?.id
                ]
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneId.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: paneId.id),
                "surfaces": surfaces,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Pane or workspace not found", data: nil)
        }
        return .ok(payload)
    }

    private func v2PaneCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid direction (left|right|up|down)", data: nil)
        }

        let panelType = v2PanelType(params, "type") ?? .terminal
        if let denial = v2SurfaceTypeDenial(panelType) { return denial }
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }
        let filePath = v2String(params, "file")
        let titleSeed = v2String(params, "title")

        // Validate and resolve markdown file path
        var resolvedMarkdownPath: String?
        if panelType == .markdown {
            if let err = v2ValidateMarkdownPath(filePath, context: "pane", resolved: &resolvedMarkdownPath) {
                return err
            }
        }

        // Validate the optional --cwd override server-side. Only meaningful for
        // terminal panes (browser/markdown have no shell), but validate
        // regardless so a bad path is rejected rather than silently ignored.
        var cwdOverride: String?
        if let err = v2ResolveCwdParam(params, resolved: &cwdOverride) {
            return err
        }

        let force = splitForceFlag(params)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create pane", data: nil)
        guard v2MainSyncWithDeadline({
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            self.v2MaybeFocusWindow(for: tabManager)
            self.v2MaybeSelectWorkspace(tabManager, workspace: ws)
            guard let focusedPanelId = ws.focusedPanelId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }

            let plan = self.planSizeAwareSplit(
                ws: ws,
                sourcePanelId: focusedPanelId,
                requested: direction,
                newIsTerminal: panelType == .terminal,
                force: force
            )

            var becameTab = false
            var appliedDirection = direction
            var warningText: String?
            var targetPaneForTab: PaneID?
            var newPanelId: UUID?

            switch plan {
            case .refuse(let message, let data):
                result = .err(code: "pane_too_small", message: message, data: data)
                return

            case .tab(let paneId, let warning):
                becameTab = true
                warningText = warning
                targetPaneForTab = paneId
                switch panelType {
                case .browser:
                    newPanelId = ws.newBrowserSurface(inPane: paneId, url: url, focus: self.v2FocusAllowed())?.id
                case .markdown:
                    newPanelId = ws.newMarkdownSurface(inPane: paneId, filePath: resolvedMarkdownPath!, focus: self.v2FocusAllowed())?.id
                case .terminal:
                    newPanelId = ws.newTerminalSurface(inPane: paneId, focus: self.v2FocusAllowed(), workingDirectory: cwdOverride)?.id
                }

            case .split(let actualDirection, _, let warning):
                appliedDirection = actualDirection
                warningText = warning
                let orientation = actualDirection.orientation
                let insertFirst = actualDirection.insertFirst
                switch panelType {
                case .browser:
                    newPanelId = ws.newBrowserSplit(from: focusedPanelId, orientation: orientation, insertFirst: insertFirst, url: url, focus: self.v2FocusAllowed())?.id
                case .markdown:
                    newPanelId = ws.newMarkdownSplit(from: focusedPanelId, orientation: orientation, insertFirst: insertFirst, filePath: resolvedMarkdownPath!, focus: self.v2FocusAllowed())?.id
                case .terminal:
                    newPanelId = ws.newTerminalSplit(from: focusedPanelId, orientation: orientation, insertFirst: insertFirst, focus: self.v2FocusAllowed(), workingDirectory: cwdOverride)?.id
                }
            }

            guard let createdPanelId = newPanelId else {
                result = .err(code: "internal_error", message: "Failed to create pane", data: nil)
                return
            }
            let paneUUID = becameTab ? targetPaneForTab?.id : ws.paneId(forPanelId: createdPanelId)?.id
            // Seed pane title atomic with the pane id becoming valid: the
            // caller observes the pane (via the response) only after the seed
            // is in the store.
            self.v2SeedPaneTitle(workspaceId: ws.id, paneUUID: paneUUID, title: titleSeed)
            let windowId = self.v2ResolveWindowId(tabManager: tabManager)
            var ok: [String: Any] = [
                "window_id": self.v2OrNull(windowId?.uuidString),
                "window_ref": self.v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": self.v2OrNull(paneUUID?.uuidString),
                "pane_ref": self.v2Ref(kind: .pane, uuid: paneUUID),
                "surface_id": createdPanelId.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: createdPanelId),
                "type": panelType.rawValue
            ]
            self.annotateSizeOutcome(&ok, requested: direction, applied: appliedDirection, becameTab: becameTab, warning: warningText)
            result = .ok(ok)
        }) != nil else {
            return .err(code: "main_thread_timeout", message: "main thread did not respond within deadline", data: nil)
        }
        return result
    }

    private func v2PaneResizeCollectCandidates(
        node: ExternalTreeNode,
        targetPaneId: String,
        candidates: inout [V2PaneResizeCandidate]
    ) -> V2PaneResizeTrace {
        switch node {
        case .pane(let pane):
            let bounds = CGRect(
                x: pane.frame.x,
                y: pane.frame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
            return V2PaneResizeTrace(containsTarget: pane.id == targetPaneId, bounds: bounds)

        case .split(let split):
            let first = v2PaneResizeCollectCandidates(
                node: split.first,
                targetPaneId: targetPaneId,
                candidates: &candidates
            )
            let second = v2PaneResizeCollectCandidates(
                node: split.second,
                targetPaneId: targetPaneId,
                candidates: &candidates
            )

            let combinedBounds = first.bounds.union(second.bounds)
            let containsTarget = first.containsTarget || second.containsTarget

            if containsTarget,
               let splitUUID = UUID(uuidString: split.id) {
                let orientation = split.orientation.lowercased()
                let axisPixels: CGFloat = orientation == "horizontal"
                    ? combinedBounds.width
                    : combinedBounds.height
                candidates.append(V2PaneResizeCandidate(
                    splitId: splitUUID,
                    orientation: orientation,
                    paneInFirstChild: first.containsTarget,
                    dividerPosition: CGFloat(split.dividerPosition),
                    axisPixels: max(axisPixels, 1)
                ))
            }

            return V2PaneResizeTrace(containsTarget: containsTarget, bounds: combinedBounds)
        }
    }

    private func v2PaneResize(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let directionRaw = (v2String(params, "direction") ?? "").lowercased()
        let amount = v2Int(params, "amount") ?? 1
        guard let direction = V2PaneResizeDirection(rawValue: directionRaw), amount > 0 else {
            return .err(code: "invalid_params", message: "direction must be one of left|right|up|down and amount must be > 0", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to resize pane", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let paneUUID = v2UUID(params, "pane_id") ?? ws.bonsplitController.focusedPaneId?.id
            guard let paneUUID else {
                result = .err(code: "not_found", message: "No focused pane", data: nil)
                return
            }
            guard ws.bonsplitController.allPaneIds.contains(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
                return
            }

            let tree = ws.bonsplitController.treeSnapshot()
            var candidates: [V2PaneResizeCandidate] = []
            let trace = v2PaneResizeCollectCandidates(
                node: tree,
                targetPaneId: paneUUID.uuidString,
                candidates: &candidates
            )
            guard trace.containsTarget else {
                result = .err(code: "not_found", message: "Pane not found in split tree", data: ["pane_id": paneUUID.uuidString])
                return
            }

            let orientationMatches = candidates.filter { $0.orientation == direction.splitOrientation }
            guard !orientationMatches.isEmpty else {
                result = .err(
                    code: "invalid_state",
                    message: "No \(direction.splitOrientation) split ancestor for pane",
                    data: ["pane_id": paneUUID.uuidString, "direction": direction.rawValue]
                )
                return
            }

            guard let candidate = orientationMatches.first(where: { $0.paneInFirstChild == direction.requiresPaneInFirstChild }) else {
                result = .err(
                    code: "invalid_state",
                    message: "Pane has no adjacent border in direction \(direction.rawValue)",
                    data: ["pane_id": paneUUID.uuidString, "direction": direction.rawValue]
                )
                return
            }

            let delta = CGFloat(amount) / candidate.axisPixels
            let requested = candidate.dividerPosition + (direction.dividerDeltaSign * delta)
            let clamped = min(max(requested, 0.1), 0.9)
            guard ws.bonsplitController.setDividerPosition(clamped, forSplit: candidate.splitId, fromExternal: true) else {
                result = .err(
                    code: "internal_error",
                    message: "Failed to set split divider position",
                    data: ["split_id": candidate.splitId.uuidString]
                )
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneUUID.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "split_id": candidate.splitId.uuidString,
                "direction": direction.rawValue,
                "amount": amount,
                "old_divider_position": candidate.dividerPosition,
                "new_divider_position": clamped
            ])
        }
        return result
    }

    private func v2PaneSwap(params: [String: Any]) -> V2CallResult {
        guard let sourcePaneUUID = v2UUID(params, "pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid pane_id", data: nil)
        }
        guard let targetPaneUUID = v2UUID(params, "target_pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid target_pane_id", data: nil)
        }
        if sourcePaneUUID == targetPaneUUID {
            return .err(code: "invalid_params", message: "pane_id and target_pane_id must be different", data: nil)
        }
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to swap panes", data: nil)
        v2MainSync {
            guard let located = v2LocatePane(sourcePaneUUID) else {
                result = .err(code: "not_found", message: "Source pane not found", data: ["pane_id": sourcePaneUUID.uuidString])
                return
            }
            guard let targetPane = located.workspace.bonsplitController.allPaneIds.first(where: { $0.id == targetPaneUUID }) else {
                result = .err(code: "not_found", message: "Target pane not found in source workspace", data: ["target_pane_id": targetPaneUUID.uuidString])
                return
            }
            let workspace = located.workspace
            let sourcePane = located.paneId

            guard let selectedSourceTab = workspace.bonsplitController.selectedTab(inPane: sourcePane),
                  let selectedTargetTab = workspace.bonsplitController.selectedTab(inPane: targetPane),
                  let sourceSurfaceId = workspace.panelIdFromSurfaceId(selectedSourceTab.id),
                  let targetSurfaceId = workspace.panelIdFromSurfaceId(selectedTargetTab.id) else {
                result = .err(code: "invalid_state", message: "Both panes must have a selected surface", data: nil)
                return
            }

            // Keep pane identities stable during swap when one side has a single surface.
            var sourcePlaceholder: UUID?
            var targetPlaceholder: UUID?
            if workspace.bonsplitController.tabs(inPane: sourcePane).count <= 1 {
                sourcePlaceholder = workspace.newTerminalSurface(inPane: sourcePane, focus: false)?.id
                if sourcePlaceholder == nil {
                    result = .err(code: "internal_error", message: "Failed to create source placeholder surface", data: nil)
                    return
                }
            }
            if workspace.bonsplitController.tabs(inPane: targetPane).count <= 1 {
                targetPlaceholder = workspace.newTerminalSurface(inPane: targetPane, focus: false)?.id
                if targetPlaceholder == nil {
                    result = .err(code: "internal_error", message: "Failed to create target placeholder surface", data: nil)
                    return
                }
            }

            guard workspace.moveSurface(panelId: sourceSurfaceId, toPane: targetPane, focus: false) else {
                result = .err(code: "internal_error", message: "Failed moving source surface into target pane", data: nil)
                return
            }
            guard workspace.moveSurface(panelId: targetSurfaceId, toPane: sourcePane, focus: false) else {
                result = .err(code: "internal_error", message: "Failed moving target surface into source pane", data: nil)
                return
            }

            if let sourcePlaceholder {
                _ = workspace.closePanel(sourcePlaceholder, force: true)
            }
            if let targetPlaceholder {
                _ = workspace.closePanel(targetPlaceholder, force: true)
            }

            if focus {
                workspace.bonsplitController.focusPane(targetPane)
            }
            let windowId = located.windowId
            result = .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "pane_id": sourcePane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: sourcePane.id),
                "target_pane_id": targetPane.id.uuidString,
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPane.id),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "target_surface_id": targetSurfaceId.uuidString,
                "target_surface_ref": v2Ref(kind: .surface, uuid: targetSurfaceId)
            ])
        }
        return result
    }

    private func v2PaneBreak(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to break pane", data: nil)
        v2MainSync {
            guard let sourceWorkspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let sourcePaneUUID = v2UUID(params, "pane_id")
            let sourcePane: PaneID? = {
                if let sourcePaneUUID {
                    return sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0.id == sourcePaneUUID })
                }
                return sourceWorkspace.bonsplitController.focusedPaneId
            }()

            let surfaceId: UUID? = {
                if let explicitSurface = v2UUID(params, "surface_id") { return explicitSurface }
                if let sourcePane,
                   let selected = sourceWorkspace.bonsplitController.selectedTab(inPane: sourcePane) {
                    return sourceWorkspace.panelIdFromSurfaceId(selected.id)
                }
                return sourceWorkspace.focusedPanelId
            }()
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No source surface to break", data: nil)
                return
            }
            guard sourceWorkspace.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            let sourceIndex = sourceWorkspace.indexInPane(forPanelId: surfaceId)
            let sourcePaneForRollback = sourceWorkspace.paneId(forPanelId: surfaceId)

            guard let detached = sourceWorkspace.detachSurface(panelId: surfaceId) else {
                result = .err(code: "internal_error", message: "Failed to detach source surface", data: nil)
                return
            }

            let destinationWorkspace = tabManager.addWorkspace(select: focus)
            guard let destinationPane = destinationWorkspace.bonsplitController.focusedPaneId
                ?? destinationWorkspace.bonsplitController.allPaneIds.first else {
                if let sourcePaneForRollback {
                    _ = sourceWorkspace.attachDetachedSurface(
                        detached,
                        inPane: sourcePaneForRollback,
                        atIndex: sourceIndex,
                        focus: true
                    )
                }
                result = .err(code: "internal_error", message: "Destination workspace has no pane", data: nil)
                return
            }

            guard destinationWorkspace.attachDetachedSurface(detached, inPane: destinationPane, focus: focus) != nil else {
                if let sourcePaneForRollback {
                    _ = sourceWorkspace.attachDetachedSurface(
                        detached,
                        inPane: sourcePaneForRollback,
                        atIndex: sourceIndex,
                        focus: true
                    )
                }
                result = .err(code: "internal_error", message: "Failed to attach surface to new workspace", data: nil)
                return
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": destinationWorkspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: destinationWorkspace.id),
                "pane_id": destinationPane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: destinationPane.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }
        return result
    }

    private func v2PaneJoin(params: [String: Any]) -> V2CallResult {
        guard let targetPaneUUID = v2UUID(params, "target_pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid target_pane_id", data: nil)
        }

        var surfaceId = v2UUID(params, "surface_id")
        if surfaceId == nil, let sourcePaneUUID = v2UUID(params, "pane_id") {
            guard let sourceLocated = v2LocatePane(sourcePaneUUID),
                  let selected = sourceLocated.workspace.bonsplitController.selectedTab(inPane: sourceLocated.paneId),
                  let selectedSurface = sourceLocated.workspace.panelIdFromSurfaceId(selected.id) else {
                return .err(code: "not_found", message: "Unable to resolve selected surface in source pane", data: [
                    "pane_id": sourcePaneUUID.uuidString
                ])
            }
            surfaceId = selectedSurface
        }
        guard let surfaceId else {
            return .err(code: "invalid_params", message: "Missing surface_id (or pane_id with selected surface)", data: nil)
        }

        var moveParams: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "pane_id": targetPaneUUID.uuidString
        ]
        if let focus = v2Bool(params, "focus") {
            moveParams["focus"] = focus
        }
        return v2SurfaceMove(params: moveParams)
    }

    private func v2PaneLast(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No alternate pane available", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let focused = ws.bonsplitController.focusedPaneId else {
                result = .err(code: "not_found", message: "No focused pane", data: nil)
                return
            }
            guard let target = ws.bonsplitController.allPaneIds.first(where: { $0.id != focused.id }) else {
                result = .err(code: "not_found", message: "No alternate pane available", data: nil)
                return
            }

            ws.bonsplitController.focusPane(target)
            let selectedSurfaceId = ws.bonsplitController.selectedTab(inPane: target).flatMap { ws.panelIdFromSurfaceId($0.id) }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": target.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: target.id),
                "surface_id": v2OrNull(selectedSurfaceId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceId)
            ])
        }
        return result
    }

    private func v2PaneSetMetadata(params: [String: Any]) -> V2CallResult {
        guard let metadataObj = params["metadata"] as? [String: Any] else {
            return .err(code: "invalid_json", message: "metadata must be a JSON object", data: nil)
        }

        let modeStr = (v2String(params, "mode") ?? "merge").lowercased()
        guard let mode = SurfaceMetadataStore.WriteMode(rawValue: modeStr) else {
            return .err(code: "invalid_mode", message: "mode must be 'merge' or 'replace'", data: nil)
        }

        let sourceStr = (v2String(params, "source") ?? "explicit").lowercased()
        guard let source = MetadataSource(rawValue: sourceStr) else {
            return .err(code: "invalid_source", message: "source must be one of: explicit, declare, osc, heuristic", data: nil)
        }
        // C11-104 v2 (B5a) — `derived` is reserved for c11-internal
        // writers. External socket/CLI clients are rejected. Without
        // this gate, an agent could write `source=derived` and claim
        // their values are system-computed, nullifying the meaning
        // of the precedence tier.
        //
        // (C11-106 AC16) Logic moved to SocketMetadataSourceValidator
        // so the rejection contract is exercised in
        // c11Tests/SocketDerivedSourceRejectionTests.swift without
        // standing up a full socket frame loop.
        if let rejection = SocketMetadataSourceValidator.externalRejectionMessage(for: source) {
            return .err(code: rejection.code, message: rejection.message, data: nil)
        }

        // C11-165 COR-1: pane metadata is a pane-scoped write; an empty or
        // absent ref must not fall back to the focused pane. `pane_id` is the
        // granularity-pinning key (surface_id/workspace_id only reach the
        // focused-pane fallback in v2ResolvePaneForMetadata).
        if let reject = v2RejectInvalidSurfaceRef(
            params,
            targetKeys: ["pane_id", "surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["pane_id"]
        ) {
            return reject
        }

        guard let resolved = v2ResolvePaneForMetadata(params: params) else {
            return .err(code: "pane_not_found", message: "Pane not found", data: nil)
        }

        do {
            let result = try PaneMetadataStore.shared.setMetadata(
                workspaceId: resolved.workspaceId,
                paneId: resolved.paneId,
                partial: metadataObj,
                mode: mode,
                source: source
            )
            return .ok(buildPaneMetadataOkPayload(
                workspaceId: resolved.workspaceId,
                paneId: resolved.paneId,
                tabManager: resolved.tabManager,
                result: result,
                includePriorValues: true
            ))
        } catch let err as SurfaceMetadataStore.WriteError {
            return .err(code: err.code, message: err.message, data: err.detailData)
        } catch {
            return .err(code: "internal_error", message: "\(error)", data: nil)
        }
    }

    private func v2PaneGetMetadata(params: [String: Any]) -> V2CallResult {
        let keys: [String]?
        if params["keys"] is NSNull || params["keys"] == nil {
            keys = nil
        } else if let arr = v2StringArray(params, "keys") {
            keys = arr
        } else {
            return .err(code: "invalid_keys_param", message: "keys must be an array of strings", data: nil)
        }

        let includeSources = v2Bool(params, "include_sources") ?? false

        guard let resolved = v2ResolvePaneForMetadata(params: params) else {
            return .err(code: "pane_not_found", message: "Pane not found", data: nil)
        }

        let (fullMetadata, fullSources) = PaneMetadataStore.shared.getMetadata(
            workspaceId: resolved.workspaceId,
            paneId: resolved.paneId
        )

        var metadataOut: [String: Any] = fullMetadata
        var sourcesOut: [String: [String: Any]] = fullSources
        if let filterKeys = keys {
            metadataOut = [:]
            sourcesOut = [:]
            for k in filterKeys {
                if let v = fullMetadata[k] { metadataOut[k] = v }
                if let s = fullSources[k] { sourcesOut[k] = s }
            }
        }

        let windowId = v2ResolveWindowId(tabManager: resolved.tabManager)
        var payload: [String: Any] = [
            "workspace_id": resolved.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: resolved.workspaceId),
            "pane_id": resolved.paneId.uuidString,
            "pane_ref": v2Ref(kind: .pane, uuid: resolved.paneId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "metadata": metadataOut
        ]
        if includeSources {
            payload["metadata_sources"] = sourcesOut
        }
        return .ok(payload)
    }

    private func v2PaneClearMetadata(params: [String: Any]) -> V2CallResult {
        let keys: [String]?
        if params["keys"] == nil || params["keys"] is NSNull {
            keys = nil
        } else if let arr = v2StringArray(params, "keys") {
            keys = arr
        } else {
            return .err(code: "invalid_keys_param", message: "keys must be an array of strings", data: nil)
        }

        let sourceStr = (v2String(params, "source") ?? "explicit").lowercased()
        guard let source = MetadataSource(rawValue: sourceStr) else {
            return .err(code: "invalid_source", message: "source must be one of: explicit, declare, osc, heuristic", data: nil)
        }
        // C11-104 v2 (B5a) — `derived` is reserved for c11-internal
        // writers. External socket/CLI clients are rejected. Without
        // this gate, an agent could write `source=derived` and claim
        // their values are system-computed, nullifying the meaning
        // of the precedence tier.
        //
        // (C11-106 AC16) Logic moved to SocketMetadataSourceValidator
        // so the rejection contract is exercised in
        // c11Tests/SocketDerivedSourceRejectionTests.swift without
        // standing up a full socket frame loop.
        if let rejection = SocketMetadataSourceValidator.externalRejectionMessage(for: source) {
            return .err(code: rejection.code, message: rejection.message, data: nil)
        }

        // C11-165 COR-1: reject empty/absent refs on this pane-scoped write;
        // never fall back to the focused pane.
        if let reject = v2RejectInvalidSurfaceRef(
            params,
            targetKeys: ["pane_id", "surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["pane_id"]
        ) {
            return reject
        }

        guard let resolved = v2ResolvePaneForMetadata(params: params) else {
            return .err(code: "pane_not_found", message: "Pane not found", data: nil)
        }

        do {
            let result = try PaneMetadataStore.shared.clearMetadata(
                workspaceId: resolved.workspaceId,
                paneId: resolved.paneId,
                keys: keys,
                source: source
            )
            return .ok(buildPaneMetadataOkPayload(
                workspaceId: resolved.workspaceId,
                paneId: resolved.paneId,
                tabManager: resolved.tabManager,
                result: result,
                includePriorValues: false
            ))
        } catch let err as SurfaceMetadataStore.WriteError {
            return .err(code: err.code, message: err.message, data: err.detailData)
        } catch {
            return .err(code: "internal_error", message: "\(error)", data: nil)
        }
    }

    /// Seed `PaneMetadataStore` with `{title: <value>}` at pane creation time.
    /// Called from `v2PaneCreate` / `v2SurfaceSplit` when the caller passes a
    /// `title` parameter. Atomic with the pane id becoming valid — agents can
    /// assume the seed is present before the RPC response returns.
    func v2SeedPaneTitle(
        workspaceId: UUID,
        paneUUID: UUID?,
        title: String?
    ) {
        guard let paneUUID, let title, !title.isEmpty else { return }
        do {
            _ = try PaneMetadataStore.shared.setMetadata(
                workspaceId: workspaceId,
                paneId: paneUUID,
                partial: [MetadataKey.title: title],
                mode: .merge,
                source: .explicit
            )
        } catch {
            // Seeding is best-effort: the pane is already created and the
            // caller can retry via pane.set_metadata. Log and continue.
            #if DEBUG
            dlog("pane.title_seed.failed pane=\(paneUUID.uuidString) err=\(error)")
            #endif
        }
    }

    /// Socket-triggered pane confirmation. Presents a .confirm interaction on the
    /// panel identified by panel_id (surface UUID) and blocks the socket call
    /// until the user accepts, cancels, or the dialog is dismissed (panel torn
    /// down mid-prompt). Per CLAUDE.md's socket threading policy, pane.confirm is
    /// an explicit focus-intent command — main-thread UI mutation is allowed.
    ///
    /// Params:
    ///   - panel_id (string, required): surface UUID of the target panel
    ///   - title (string, required): card title
    ///   - message (string, optional): card informative text
    ///   - role (string, optional): "destructive" | "standard" (default: standard)
    ///   - timeout (number, optional): max seconds to wait; clamped to [0, 300].
    ///     Omitting defaults to 300 seconds — the server-side ceiling prevents a
    ///     malformed or malicious caller from blocking a socket worker with an
    ///     indefinite wait. Caller-supplied values > 300s are silently clamped.
    ///   - confirm_label (string, optional): override for the confirm button label
    ///   - cancel_label (string, optional): override for the cancel button label
    ///
    /// Result: { "result": "ok" | "cancel" | "dismissed" }
    ///
    /// Errors:
    ///   - "unavailable" — no TabManager
    ///   - "invalid_params" — missing panel_id or title
    ///   - "unknown_panel" — panel_id doesn't resolve to a panel in any workspace
    private func v2PaneConfirm(params: [String: Any]) -> V2CallResult {
        // Document and enforce the off-main contract: v2PaneConfirm blocks the
        // calling thread on a DispatchSemaphore, so running this on main would
        // hang the UI (v2MainSync falls through to direct execution when
        // already on main, which would then dead-wait). Socket dispatch runs
        // off-main via Thread.detachNewThread; this guard catches regressions.
        assert(!Thread.isMainThread, "v2PaneConfirm must not be called on the main thread")

        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let panelId = v2UUID(params, "panel_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid panel_id", data: nil)
        }
        guard let title = v2String(params, "title"), !title.isEmpty else {
            return .err(code: "invalid_params", message: "Missing or empty title", data: nil)
        }
        let message = (v2String(params, "message") ?? "")
        let roleStr = v2String(params, "role") ?? "standard"
        let role: ConfirmContent.ConfirmRole = (roleStr == "destructive") ? .destructive : .standard
        // Cap user-supplied timeout at 300s so a malformed or malicious caller
        // can't starve the socket worker pool with a .distantFuture wait.
        let maxTimeoutSeconds: Double = 300
        let timeoutSeconds = (params["timeout"] as? Double).map { min(maxTimeoutSeconds, max(0, $0)) }
        let clientId = (v2String(params, "_clientId")) ?? "socket"

        // Optional confirm/cancel label overrides. Falls back to a neutral
        // "OK" key (dialog.pane.confirm.ok) — NOT the close-specific key that
        // localizes to "Close"/"閉じる" and is semantically wrong for generic
        // socket-initiated prompts (synthesis-standard §1.3).
        let confirmLabel = v2String(params, "confirm_label").flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "dialog.pane.confirm.ok", defaultValue: "OK")
        let cancelLabel = v2String(params, "cancel_label").flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "dialog.pane.confirm.cancel", defaultValue: "Cancel")

        let semaphore = DispatchSemaphore(value: 0)
        // `outcome` is written from the main-actor completion callback and read
        // after the semaphore is signaled — single-writer, single-reader with
        // happens-before ordering provided by the semaphore.
        final class OutcomeHolder {
            var value: ConfirmResult = .dismissed
            var fired: Bool = false
        }
        let holder = OutcomeHolder()
        var presented = false
        var presentedInteractionId: UUID?

        v2MainSync {
            // Find the workspace that owns this panel. Iterate tabs across the
            // resolved TabManager — pane.confirm accepts any workspace's panel.
            guard let workspace = tabManager.tabs.first(where: { $0.panels[panelId] != nil }) else {
                return
            }
            let content = ConfirmContent(
                title: title,
                message: message.isEmpty ? nil : message,
                confirmLabel: confirmLabel,
                cancelLabel: cancelLabel,
                role: role,
                source: .socket(clientId: clientId),
                completion: { result in
                    holder.value = result
                    holder.fired = true
                    semaphore.signal()
                }
            )
            workspace.paneInteractionRuntime.present(
                panelId: panelId,
                interaction: .confirm(content)
            )
            presentedInteractionId = content.id
            presented = true
        }

        guard presented else {
            return .err(code: "unknown_panel", message: "Panel not found", data: ["panel_id": panelId.uuidString])
        }

        // Block the socket thread until the user responds or the timeout fires.
        let waitDeadline: DispatchTime
        if let timeoutSeconds {
            waitDeadline = .now() + timeoutSeconds
        } else {
            waitDeadline = .now() + maxTimeoutSeconds
        }
        let waitResult = semaphore.wait(timeout: waitDeadline)
        if waitResult == .timedOut {
            // Accept/timeout race: the user may have clicked Confirm just as the
            // timeout fired. Re-read holder on the main thread before cancelling,
            // and if the completion fired (holder.fired == true) return the user's
            // actual outcome instead of overwriting with dismissed.
            let raced: ConfirmResult? = v2MainSync {
                if holder.fired {
                    return holder.value
                }
                if let workspace = tabManager.tabs.first(where: { $0.panels[panelId] != nil }) {
                    // Interaction-ID-guarded cancel: never cancel a successor
                    // that advanced after our present (synthesis-critical §1.5).
                    workspace.paneInteractionRuntime.cancelActive(
                        panelId: panelId,
                        ifInteractionId: presentedInteractionId
                    )
                }
                return nil
            }
            if let raced {
                return v2EncodePaneConfirmResult(raced)
            }
            return .ok(["result": "dismissed"])
        }

        return v2EncodePaneConfirmResult(holder.value)
    }

    private func v2EncodePaneConfirmResult(_ result: ConfirmResult) -> V2CallResult {
        switch result {
        case .confirmed:
            return .ok(["result": "ok"])
        case .cancelled:
            return .ok(["result": "cancel"])
        case .dismissed:
            return .ok(["result": "dismissed"])
        }
    }
}
