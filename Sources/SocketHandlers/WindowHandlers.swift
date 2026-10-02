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
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private func v2WindowList(params _: [String: Any]) -> V2CallResult {
        let windows = v2MainSync { AppDelegate.shared?.listMainWindowSummaries() } ?? []
        let payload: [[String: Any]] = windows.enumerated().map { index, item in
            return [
                "id": item.windowId.uuidString,
                "ref": v2Ref(kind: .window, uuid: item.windowId),
                "index": index,
                "key": item.isKeyWindow,
                "visible": item.isVisible,
                "workspace_count": item.workspaceCount,
                "selected_workspace_id": v2OrNull(item.selectedWorkspaceId?.uuidString),
                "selected_workspace_ref": v2Ref(kind: .workspace, uuid: item.selectedWorkspaceId)
            ]
        }
        return .ok(["windows": payload])
    }

    private func v2WindowCurrent(params _: [String: Any]) -> V2CallResult {
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
        let ok = v2MainSync { AppDelegate.shared?.closeMainWindow(windowId: windowId) ?? false }
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

}

private func windowResizeRectPayload(_ rect: CGRect) -> [String: CGFloat] {
    ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
}
