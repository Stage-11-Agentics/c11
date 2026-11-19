import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// v2 dispatch slice for the `theme.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchTheme(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "theme.list":
            return v2Result(id: id, .ok(ThemeSocketMethods.list()))
        case "theme.get":
            // c11 (C11H-197): with window_id, also the window's own theme.
            guard params["window_id"] != nil else {
                return v2Result(id: id, .ok(ThemeSocketMethods.get(params: params)))
            }
            if let rejection = v2RejectUnresolvedTargetRefs(params) { return v2Result(id: id, rejection) }
            guard let windowId = v2UUID(params, "window_id"),
                  let geometry = v2MainSync({ AppDelegate.shared?.mainWindowGeometry(windowId: windowId) }) else {
                return v2Error(id: id, code: "not_found", message: "Window not found")
            }
            var payload = ThemeSocketMethods.get(params: params)
            payload["window"] = [
                "id": windowId.uuidString,
                "ref": v2Ref(kind: .window, uuid: windowId),
                "name": geometry.name ?? NSNull(),
                "override": geometry.themeOverride ?? NSNull(),
                "effective": geometry.effectiveTheme
            ] as [String: Any]
            return v2Result(id: id, .ok(payload))
        case "theme.set_active":
            return v2Result(id: id, .ok(ThemeSocketMethods.setActive(params: params)))
        case "theme.clear_active":
            return v2Result(id: id, .ok(ThemeSocketMethods.clearActive()))
        case "theme.reload":
            return v2Result(id: id, .ok(ThemeSocketMethods.reload()))
        case "theme.paths":
            return v2Result(id: id, .ok(ThemeSocketMethods.paths()))
        case "theme.dump":
            return v2Result(id: id, .ok(ThemeSocketMethods.dumpActive(params: params)))
        case "theme.validate":
            return v2Result(id: id, .ok(ThemeSocketMethods.validate(params: params)))
        case "theme.diff":
            return v2Result(id: id, .ok(ThemeSocketMethods.diff(params: params)))
        case "theme.inherit":
            return v2Result(id: id, .ok(ThemeSocketMethods.inherit(params: params)))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }


}
