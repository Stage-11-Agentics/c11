import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// v2 dispatch slice for the `markdown.*,feedback.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchMarkdownFeedback(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "feedback.open":
            return v2Result(id: id, self.v2FeedbackOpen(params: params))
        case "feedback.submit":
            return v2Result(id: id, self.v2FeedbackSubmit(params: params))
        case "markdown.open":
            return v2Result(id: id, self.v2MarkdownOpen(params: params))
        case "markdown.get_content":
            return v2Result(id: id, self.v2MarkdownGetContent(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private func v2FeedbackOpen(params: [String: Any]) -> V2CallResult {
        let workspaceId = v2UUID(params, "workspace_id")
        let windowId = v2UUID(params, "window_id")
        let shouldActivate = v2Bool(params, "activate") ?? false
        DispatchQueue.main.async {
            let targetWindow: NSWindow?
            if let windowId, let app = AppDelegate.shared {
                targetWindow = app.mainWindow(for: windowId)
            } else if let workspaceId, let app = AppDelegate.shared {
                targetWindow = app.mainWindowContainingWorkspace(workspaceId)
            } else {
                targetWindow = nil
            }

            if shouldActivate {
                if let targetWindow {
                    targetWindow.makeKeyAndOrderFront(nil)
                    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                } else {
                    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                }
            }

            FeedbackComposerBridge.openComposer(in: targetWindow)
        }
        return .ok(["opened": true])
    }

    private func v2FeedbackSubmit(params: [String: Any]) -> V2CallResult {
        guard let email = params["email"] as? String else {
            return .err(code: "invalid_params", message: "Missing email", data: ["field": "email"])
        }
        guard let body = params["body"] as? String else {
            return .err(code: "invalid_params", message: "Missing body", data: ["field": "body"])
        }
        let imagePaths = params["image_paths"] as? [String] ?? []

        let semaphore = DispatchSemaphore(value: 0)
        var result: V2CallResult = .err(code: "internal_error", message: "Feedback submission failed", data: nil)

        Task {
            let resolved: V2CallResult
            do {
                let attachmentCount = try await FeedbackComposerBridge.submit(
                    email: email,
                    message: body,
                    imagePaths: imagePaths
                )
                resolved = .ok([
                    "submitted": true,
                    "attachment_count": attachmentCount,
                ])
            } catch let error as FeedbackComposerBridgeError {
                let code: String
                switch error {
                case .invalidEmail, .emptyMessage, .messageTooLong, .tooManyImages, .invalidImagePath:
                    code = "invalid_params"
                case .submissionFailed:
                    code = "request_failed"
                }
                resolved = .err(code: code, message: error.localizedDescription, data: nil)
            } catch {
                resolved = .err(code: "internal_error", message: error.localizedDescription, data: nil)
            }

            result = resolved
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            return .err(code: "timeout", message: "Feedback submission timed out", data: nil)
        }

        return result
    }

    private func v2MarkdownOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawPath = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing 'path' parameter", data: nil)
        }

        // Resolve the path (expand ~ and standardize)
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let filePath = NSString(string: expandedPath).standardizingPath

        // Reject paths that aren't absolute after resolution
        guard filePath.hasPrefix("/") else {
            return .err(code: "invalid_params", message: "Path must be absolute: \(filePath)", data: ["path": filePath])
        }

        // Validate the file exists and is a regular file (not a directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
            return .err(code: "not_found", message: "File not found: \(filePath)", data: ["path": filePath])
        }
        guard !isDir.boolValue else {
            return .err(code: "invalid_params", message: "Path is a directory, not a file: \(filePath)", data: ["path": filePath])
        }
        guard FileManager.default.isReadableFile(atPath: filePath) else {
            return .err(code: "permission_denied", message: "File not readable: \(filePath)", data: ["path": filePath])
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
        v2MainSync {
            // M6 — if pane_id is supplied, locate the owning workspace across all
            // windows so `markdown.open --pane P` works standalone (spec: --pane
            // uniquely identifies). This takes precedence over workspace_id/window_id
            // (which may be injected from env vars by the CLI).
            var resolvedTabManager: TabManager = tabManager
            var resolvedWorkspace: Workspace?
            if v2HasNonNullParam(params, "pane_id") {
                guard let paneUUID = v2UUID(params, "pane_id") else {
                    result = .err(code: "invalid_params", message: "Invalid pane_id", data: nil)
                    return
                }
                if let located = AppDelegate.shared?.locatePane(paneId: paneUUID) {
                    resolvedWorkspace = located.workspace
                    resolvedTabManager = located.tabManager
                }
            }
            guard let ws = resolvedWorkspace ?? v2ResolveWorkspace(params: params, tabManager: resolvedTabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: resolvedTabManager)
            v2MaybeSelectWorkspace(resolvedTabManager, workspace: ws)

            // M6 — if pane_id is supplied, open as a tab inside that pane (no split).
            if v2HasNonNullParam(params, "pane_id") {
                guard let paneUUID = v2UUID(params, "pane_id") else {
                    result = .err(code: "invalid_params", message: "Invalid pane_id", data: nil)
                    return
                }
                guard let targetPaneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                    result = .err(code: "not_found", message: "Pane not found in workspace", data: ["pane_id": paneUUID.uuidString])
                    return
                }

                let createdPanel = ws.newMarkdownSurface(
                    inPane: targetPaneId,
                    filePath: filePath,
                    focus: v2FocusAllowed()
                )

                guard let markdownPanelId = createdPanel?.id else {
                    result = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
                    return
                }

                let windowId = v2ResolveWindowId(tabManager: resolvedTabManager)
                result = .ok([
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": targetPaneId.id.uuidString,
                    "pane_ref": v2Ref(kind: .pane, uuid: targetPaneId.id),
                    "surface_id": markdownPanelId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: markdownPanelId),
                    "target_pane_id": targetPaneId.id.uuidString,
                    "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneId.id),
                    "path": filePath
                ])
                return
            }

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Source surface not found", data: ["surface_id": sourceSurfaceId.uuidString])
                return
            }

            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            let createdPanel = ws.newMarkdownSplit(
                from: sourceSurfaceId,
                orientation: .horizontal,
                filePath: filePath,
                focus: v2FocusAllowed()
            )

            guard let markdownPanelId = createdPanel?.id else {
                result = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: markdownPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": markdownPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: markdownPanelId),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "path": filePath
            ])
        }
        return result
    }

    private func v2MarkdownGetContent(params: [String: Any]) -> V2CallResult {
        guard let resolved = v2ResolveWorkspaceSurface(params: params) else {
            return .err(code: "not_found", message: "Surface not found", data: nil)
        }
        let (ws, surfaceId) = resolved

        var payload: [String: Any]?
        var errResult: V2CallResult?
        v2MainSync {
            guard let panel = ws.panels[surfaceId] else {
                errResult = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard let markdown = panel as? MarkdownPanel else {
                errResult = .err(code: "invalid_params", message: "Surface is not a markdown panel", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let content = markdown.content
            let contentBytes = content.data(using: .utf8) ?? Data()
            let sha = SHA256.hash(data: contentBytes).map { String(format: "%02x", $0) }.joined()
            let softCap = 256 * 1024

            var out: [String: Any] = [
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "type": PanelType.markdown.rawValue,
                "file_path": markdown.filePath,
                "content_length": contentBytes.count,
                "content_sha256": sha,
                "is_file_unavailable": markdown.isFileUnavailable
            ]
            if contentBytes.count > softCap {
                out["truncated"] = true
                out["reason"] = "content_too_large"
            } else {
                out["content"] = content
            }
            payload = out
        }
        if let errResult { return errResult }
        guard let out = payload else {
            return .err(code: "not_found", message: "Surface not found", data: nil)
        }
        return .ok(out)
    }
}
