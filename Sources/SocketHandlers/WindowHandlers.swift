import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import CoreFoundation
import Bonsplit
import WebKit

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
// Runs on the main actor (inherited from the @MainActor class), exactly as the
// original switch cases did.
extension TerminalController {
    /// v2 dispatch slice for the `window.*` domain. Byte-identical routing and
    /// wire responses to the original `processV2Command` cases.
    func v2DispatchWindow(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "window.list":
            return v2Result(id: id, self.v2WindowList(params: params))
        case "window.current":
            return v2Result(id: id, self.v2WindowCurrent(params: params))
        case "window.focus":
            return v2Result(id: id, self.v2WindowFocus(params: params))
        case "window.create":
            return v2Result(id: id, self.v2WindowCreate(params: params))
        case "window.close":
            return v2Result(id: id, self.v2RejectUnresolvedTargetRefs(params) ?? self.v2WindowClose(params: params))
        case "window.resize":
            return v2WindowResizeWorker(id: id, params: params)
        // c11 (C11H-197): names, themes, placement and displays read and write
        // AppKit window and screen state, so they run on main like window.list.
        case "window.set_name":
            return v2Result(id: id, v2RejectUnresolvedTargetRefs(params) ?? self.v2WindowSetName(params: params))
        case "window.set_theme":
            return v2Result(id: id, v2RejectUnresolvedTargetRefs(params) ?? self.v2WindowSetTheme(params: params))
        case "window.move":
            return v2Result(id: id, v2RejectUnresolvedTargetRefs(params) ?? self.v2WindowMove(params: params))
        case "display.list":
            return v2Result(id: id, self.v2DisplayList(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private func v2WindowList(params _: [String: Any]) -> V2CallResult {
        let relayScope = SocketCommandContext.current?.relayReadScope
        let (windows, geometry, scopeWindow) = v2MainSync {
            (AppDelegate.shared?.listMainWindowSummaries() ?? [], AppDelegate.shared?.allMainWindowGeometry() ?? [:],
             relayScope.flatMap { relayScopeWindowId($0) })
        }
        let payload: [[String: Any]] = windows.enumerated().compactMap { index, item in
            // C11H-371: a relayed caller sees only the window that holds its
            // workspace, and none of that window's other workspaces.
            if let relayScope {
                guard item.windowId == scopeWindow else { return nil }
                let own = item.selectedWorkspaceId == relayScope.workspace ? relayScope.workspace : nil
                return v2WindowListEntry(item, index: index, workspaceCount: 1, selectedWorkspaceId: own,
                                         geometry: geometry[item.windowId])
            }
            return v2WindowListEntry(item, index: index, workspaceCount: item.workspaceCount,
                                     selectedWorkspaceId: item.selectedWorkspaceId, geometry: geometry[item.windowId])
        }
        return .ok(["windows": payload, "coordinate_space": WindowGeometryPayload.coordinateSpace])
    }

    private func v2WindowListEntry(_ item: AppDelegate.MainWindowSummary, index: Int, workspaceCount: Int,
                                   selectedWorkspaceId: UUID?, geometry: MainWindowGeometry?) -> [String: Any] {
        var entry: [String: Any] = [
            "id": item.windowId.uuidString,
            "ref": v2Ref(kind: .window, uuid: item.windowId),
            "index": index,
            "key": item.isKeyWindow,
            "visible": item.isVisible,
            "workspace_count": workspaceCount,
            "selected_workspace_id": v2OrNull(selectedWorkspaceId?.uuidString),
            "selected_workspace_ref": v2Ref(kind: .workspace, uuid: selectedWorkspaceId)
        ]
        // c11 (C11H-197): name, theme, display and frame (global points, top-left origin).
        if let geometry {
            entry.merge(WindowGeometryPayload.window(geometry)) { current, _ in current }
        }
        return entry
    }

    // MARK: c11 (C11H-197) window names, themes, placement and displays

    private func v2WindowAttributeTarget(_ params: [String: Any]) -> UUID? {
        v2UUID(params, "window_id")
    }

    private func v2WindowSetName(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2WindowAttributeTarget(params) else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let raw = params["name"]
        guard raw == nil || raw is NSNull || raw is String else {
            return .err(code: "invalid_params", message: "name must be a string or null", data: nil)
        }
        let result = v2MainSync { AppDelegate.shared?.setMainWindowName(windowId: windowId, name: raw as? String) }
        switch result {
        case .success(let name):
            return .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "name": name ?? NSNull()
            ])
        case .failure(.invalidName(let rejection)):
            return .err(code: "invalid_params", message: Self.windowNameRejectionMessage(rejection), data: [
                "reason": Self.windowNameRejectionCode(rejection)
            ])
        case .failure, nil:
            return .err(code: "not_found", message: "Window not found", data: ["window_id": windowId.uuidString])
        }
    }

    nonisolated static func windowNameRejectionCode(_ rejection: WindowNamePolicy.Rejection) -> String {
        switch rejection {
        case .empty: return "empty"
        case .tooLong: return "too_long"
        case .looksLikeRef: return "looks_like_ref"
        case .inUse: return "in_use"
        }
    }

    nonisolated static func windowNameRejectionMessage(_ rejection: WindowNamePolicy.Rejection) -> String {
        switch rejection {
        case .empty:
            return "A window name cannot be empty; pass --clear to remove one."
        case .tooLong:
            return "A window name is at most \(WindowNamePolicy.maxLength) characters."
        case .looksLikeRef:
            return "A window name cannot be a number, a UUID, self, or a ref like window:2, because names are accepted as --window refs."
        case .inUse(let other):
            return "Another window (\(other.uuidString)) already has that name; names are unique, ignoring case."
        }
    }

    private func v2WindowSetTheme(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2WindowAttributeTarget(params) else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let raw = params["theme"]
        guard raw == nil || raw is NSNull || raw is String else {
            return .err(code: "invalid_params", message: "theme must be a string or null", data: nil)
        }
        let result = v2MainSync { () -> (Result<String?, AppDelegate.WindowAttributeFailure>, MainWindowGeometry?)? in
            guard let app = AppDelegate.shared else { return nil }
            let applied = app.setMainWindowTheme(windowId: windowId, themeName: raw as? String)
            return (applied, app.mainWindowGeometry(windowId: windowId))
        }
        switch result?.0 {
        case .success:
            return .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "theme": [
                    "override": result?.1?.themeOverride ?? NSNull(),
                    "effective": result?.1?.effectiveTheme ?? NSNull()
                ] as [String: Any]
            ])
        case .failure(.unknownTheme(let name)):
            let available = v2MainSync { ThemeManager.shared.availableThemes.map(\.identity.name) }
            return .err(code: "invalid_params", message: "Unknown theme: \(name)", data: ["available": available])
        case .failure, nil:
            return .err(code: "not_found", message: "Window not found", data: ["window_id": windowId.uuidString])
        }
    }

    private func v2WindowMove(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2WindowAttributeTarget(params) else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var displayRef: String?
        switch params["display"] {
        case nil, is NSNull: displayRef = nil
        case let text as String: displayRef = text
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): displayRef = number.stringValue
        default:
            return .err(code: "invalid_params", message: "display must be a display ref", data: nil)
        }
        var frame: CGRect?
        if let rawFrame = params["frame"], !(rawFrame is NSNull) {
            guard let object = rawFrame as? [String: Any],
                  let rect = Self.windowMoveRect(object) else {
                return .err(code: "invalid_params", message: "frame must be {x, y, width, height} in points", data: nil)
            }
            frame = rect
        }
        var preset: WindowPlacementPlan.Preset?
        if let rawPreset = params["preset"], !(rawPreset is NSNull) {
            guard let text = rawPreset as? String, let parsed = WindowPlacementPlan.Preset(rawValue: text) else {
                return .err(code: "invalid_params", message: "preset must be fill, left-half or right-half", data: nil)
            }
            preset = parsed
        }
        let result = v2MainSync {
            AppDelegate.shared?.moveMainWindow(windowId: windowId, displayRef: displayRef, frame: frame, preset: preset)
        }
        switch result {
        case .success(let moved):
            var payload = WindowGeometryPayload.window(moved.after)
            payload["window_id"] = windowId.uuidString
            payload["window_ref"] = v2Ref(kind: .window, uuid: windowId)
            payload["requested"] = moved.requested.c11Payload
            payload["changed"] = moved.changed
            payload["display_changed"] = moved.before.display?.displayID != moved.after.display?.displayID
            payload["coordinate_space"] = WindowGeometryPayload.coordinateSpace
            return .ok(payload)
        case .failure(.fullscreen):
            return .err(code: "invalid_state", message: "That window is full screen. window move does not enter or leave full screen.", data: nil)
        case .failure(.minimized):
            return .err(code: "invalid_state", message: "That window is minimized. Ask the operator to restore it first.", data: nil)
        case .failure(.noDisplays):
            return .err(code: "unavailable", message: "No displays are connected.", data: nil)
        case .failure(.display(.notFound(let ref))):
            return .err(code: "not_found", message: "No display matches \(ref). Run display list.", data: nil)
        case .failure(.display(.ambiguous(let ref, let candidates))):
            return .err(code: "ambiguous", message: "\(ref) names more than one display: \(candidates.joined(separator: ", ")).", data: ["candidates": candidates])
        case .failure(.plan(.nothingToDo)):
            return .err(code: "invalid_params", message: "Give a display, a frame, or a preset (fill, left-half, right-half).", data: nil)
        case .failure(.plan(.conflicting)):
            return .err(code: "invalid_params", message: "Give a frame or a preset, not both.", data: nil)
        case .failure(.plan(.invalidFrame)):
            return .err(code: "invalid_params", message: "frame needs finite numbers and a positive width and height.", data: nil)
        case .failure(.plan(.noDisplay)):
            return .err(code: "invalid_state", message: "The window's display is unknown; pass a display.", data: nil)
        case .failure(.notFound), nil:
            return .err(code: "not_found", message: "Window not found", data: ["window_id": windowId.uuidString])
        }
    }

    nonisolated static func windowMoveRect(_ object: [String: Any]) -> CGRect? {
        func number(_ key: String) -> CGFloat? {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite else { return nil }
            return CGFloat(value.doubleValue)
        }
        guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height") else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func v2DisplayList(params _: [String: Any]) -> V2CallResult {
        let relayScope = SocketCommandContext.current?.relayReadScope
        let (displays, geometry, scopeWindow) = v2MainSync { () -> ([DisplayGeometry], [UUID: MainWindowGeometry], UUID?) in
            let displays = AppDelegate.currentDisplayGeometry()
            return (displays, AppDelegate.shared?.allMainWindowGeometry(displays: displays) ?? [:],
                    relayScope.flatMap { relayScopeWindowId($0) })
        }
        let payload: [[String: Any]] = displays.map { display in
            var entry = WindowGeometryPayload.display(display)
            entry["windows"] = geometry.values
                .filter { $0.display?.displayID == display.displayID }
                // C11H-371: a relayed caller sees only the window that holds its workspace.
                .filter { relayScope == nil || $0.windowId == scopeWindow }
                .sorted { ($0.frame?.minX ?? 0, $0.windowId.uuidString) < ($1.frame?.minX ?? 0, $1.windowId.uuidString) }
                .map { window -> [String: Any] in
                    [
                        "id": window.windowId.uuidString,
                        "ref": v2Ref(kind: .window, uuid: window.windowId),
                        "name": window.name ?? NSNull(),
                        "visible_fraction": window.visibleFraction ?? NSNull()
                    ]
                }
            return entry
        }
        return .ok(["displays": payload, "coordinate_space": WindowGeometryPayload.coordinateSpace])
    }

    private func v2WindowCurrent(params _: [String: Any]) -> V2CallResult {
        // C11H-371: through the relay the current window is the one that
        // holds the caller's workspace, never the operator's.
        if let scope = SocketCommandContext.current?.relayReadScope {
            guard let windowId = v2MainSync({ relayScopeWindowId(scope) }) else {
                return .err(code: "not_found", message: "Current window not found", data: nil)
            }
            return .ok(["window_id": windowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: windowId)])
        }
        guard let workspaceManager else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let windowId = v2ResolveWindowId(workspaceManager: workspaceManager) else {
            return .err(code: "not_found", message: "Current window not found", data: nil)
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ])
    }

    private func v2WindowFocus(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let ok = v2MainSync { AppDelegate.shared?.focusMainWindow(windowId: windowId) ?? false }
        return ok
            ? .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
            : .err(code: "not_found", message: "Window not found", data: [
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
    }

    private func v2WindowCreate(params _: [String: Any]) -> V2CallResult {
        // Two-step unwrap: outer nil = deadline fired; inner nil = AppDelegate.shared unavailable.
        let rawWindowId = v2MainSyncWithDeadline({ AppDelegate.shared?.createMainWindow() })
        guard let rawWindowId else {
            return .err(code: "main_thread_timeout", message: "main thread did not respond within deadline", data: nil)
        }
        guard let windowId = rawWindowId else {
            return .err(code: "internal_error", message: "Failed to create window", data: nil)
        }
        // The new window should become key, but setActiveTabManager defensively.
        if let tm = v2MainSync({ AppDelegate.shared?.workspaceManagerFor(windowId: windowId) }) {
            setActiveWorkspaceManager(tm)
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ])
    }

    /// Parse the request on the socket worker, then resolve its live window ref
    /// and read/write the AppKit frame together in one bounded main-actor hop.
    nonisolated func v2WindowResizeWorker(id: Any?, params: [String: Any]) -> String {
        guard CapabilityFeatures.current.supports(.windowResize) else {
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }

        func dimension(_ key: String) -> (value: CGFloat?, valid: Bool) {
            guard let raw = params[key] else { return (nil, true) }
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else {
                return (nil, false)
            }
            return (CGFloat(number.doubleValue), true)
        }

        let width = dimension("width")
        let height = dimension("height")
        let result: V2CallResult
        if Thread.isMainThread {
            result = MainActor.assumeIsolated {
                self.v2WindowResizeOnMain(params: params, width: width, height: height)
            }
        } else {
            result = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self.v2WindowResizeOnMain(params: params, width: width, height: height)
                }
            }
        }
        return v2Result(id: id, result)
    }

    private func v2WindowResizeOnMain(
        params: [String: Any],
        width: (value: CGFloat?, valid: Bool),
        height: (value: CGFloat?, valid: Bool)
    ) -> V2CallResult {
        if let rejection = v2RejectUnresolvedTargetRefs(params) {
            return rejection
        }
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: String(localized: "socket.error.window_id", defaultValue: "Missing or invalid window_id"), data: nil)
        }
        guard width.valid, height.valid else {
            return .err(code: "invalid_params", message: String(localized: "socket.error.window_resize_params", defaultValue: "Width and height must be finite numbers."), data: nil)
        }

        // This runs inside the same main-actor hop as target resolution above.
        let result = AppDelegate.shared?.resizeMainWindow(windowId: windowId, width: width.value, height: height.value)
        switch result {
        case .success(let applied):
            return .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "requested": ["width": width.value.map { $0 as Any } ?? NSNull(), "height": height.value.map { $0 as Any } ?? NSNull()],
                "applied": ["width": applied.frame.width, "height": applied.frame.height],
                "origin": ["x": applied.frame.origin.x, "y": applied.frame.origin.y],
                "top_left": ["x": applied.frame.origin.x, "y": applied.frame.maxY],
                "screen": applied.screenFrame.map { screenFrame -> Any in
                    [
                        "display_id": applied.screenDisplayID.map { $0 as Any } ?? NSNull(),
                        "frame": windowResizeRectPayload(screenFrame),
                        "visible_frame": applied.screenVisibleFrame.map(windowResizeRectPayload) ?? NSNull()
                    ] as [String: Any]
                } ?? NSNull(),
                "clamped": applied.clamped,
                "changed": applied.changed
            ])
        case .failure(.fullscreen):
            return .err(code: "invalid_state", message: String(localized: "socket.error.window_fullscreen", defaultValue: "That window is fullscreen. resize-window does not enter or leave fullscreen."), data: nil)
        case .failure(.notFound), nil:
            return .err(code: "not_found", message: String(localized: "socket.error.window_not_found", defaultValue: "Window not found"), data: ["window_id": windowId.uuidString])
        }
    }

    private func v2WindowClose(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let result = v2MainSync { AppDelegate.shared?.closeMainWindow(windowId: windowId) ?? .notFound }
        switch result {
        case .closed:
            return .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        case .invalidState:
            return .err(code: "invalid_state", message: "Window has an attached sheet", data: [
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        case .notFound:
            return .err(code: "not_found", message: "Window not found", data: [
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
    }

}

private func windowResizeRectPayload(_ rect: CGRect) -> [String: CGFloat] {
    ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
}
