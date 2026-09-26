import AppKit
import SwiftUI

/// C11-238: the operator-facing edits of a workspace's root directory, shared
/// by the title-bar info popover and the sidebar row's context menu. Every
/// write goes through `Workspace.setRootDirectory`, the same call the
/// `workspace.set_root` socket verb makes.
@MainActor
enum WorkspaceRootActions {
    /// The focused surface's shell cwd (the workspace's `currentDirectory`
    /// when the focused panel has not reported one).
    static func focusedDirectory(of workspace: Workspace) -> String? {
        if let focusedPanelId = workspace.focusedPanelId,
           let reported = workspace.panelDirectories[focusedPanelId]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !reported.isEmpty {
            return reported
        }
        let current = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.isEmpty ? nil : current
    }

    /// The focused cwd when it differs from the root, else nil: the drift the
    /// operator should see.
    static func driftedFocusedDirectory(of workspace: Workspace) -> String? {
        guard let focused = focusedDirectory(of: workspace) else { return nil }
        let standardized = NSString(string: focused).standardizingPath
        return standardized == workspace.rootDirectory ? nil : standardized
    }

    /// String-only drift check with no filesystem access, for the sidebar
    /// row's context menu (built in `TabItemView.body`, a typing-path view).
    /// The action re-validates with `canUseFocusedDirectory`.
    static func mayUseFocusedDirectory(for workspace: Workspace) -> Bool {
        guard workspace.remoteConfiguration == nil,
              let focused = focusedDirectory(of: workspace) else { return false }
        return comparablePath(focused) != workspace.rootDirectory.map(comparablePath)
    }

    /// Normalizes a path for equality without touching the filesystem: dot
    /// segments and trailing slashes collapse, and the `/private` alias of
    /// `/tmp`, `/var` and `/etc` folds away the way stored roots already do.
    nonisolated static func comparablePath(_ path: String) -> String {
        var normalized = URL(fileURLWithPath: path, isDirectory: true).standardized.path
        for alias in ["/private/tmp", "/private/var", "/private/etc"]
        where normalized == alias || normalized.hasPrefix(alias + "/") {
            normalized.removeFirst("/private".count)
            break
        }
        return normalized
    }

    /// Remote workspaces report remote paths, which are not local directories.
    static func canUseFocusedDirectory(for workspace: Workspace) -> Bool {
        guard workspace.remoteConfiguration == nil,
              let drifted = driftedFocusedDirectory(of: workspace) else { return false }
        return Workspace.isExistingDirectory(drifted)
    }

    static func useFocusedDirectory(for workspace: Workspace) {
        guard canUseFocusedDirectory(for: workspace),
              let drifted = driftedFocusedDirectory(of: workspace) else { return }
        workspace.setRootDirectory(drifted)
    }

    static func clearRoot(for workspace: Workspace) {
        workspace.setRootDirectory(nil)
    }

    /// Non-modal folder chooser; nothing on this path blocks the main run loop.
    static func chooseRoot(for workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "workspaceRoot.openPanel.prompt", defaultValue: "Set Root")
        panel.message = String(
            localized: "workspaceRoot.openPanel.message",
            defaultValue: "Choose the directory new terminals in this workspace start in."
        )
        let start = workspace.rootDirectory.flatMap { Workspace.isExistingDirectory($0) ? $0 : nil }
            ?? focusedDirectory(of: workspace)
        if let start {
            panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true)
        }
        panel.begin { [weak workspace] response in
            guard response == .OK, let url = panel.url else { return }
            let path = url.standardizedFileURL.path
            guard Workspace.isExistingDirectory(path) else { return }
            MainActor.assumeIsolated {
                workspace?.setRootDirectory(path)
            }
        }
    }

    static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Menu item titles never truncate on their own; keep the head and the
    /// project-identifying tail so the submenu stays a sane width.
    static func menuDisplayPath(_ path: String, maxLength: Int = 60) -> String {
        let display = displayPath(path)
        guard display.count > maxLength else { return display }
        let tail = (maxLength * 2) / 3
        let head = maxLength - tail - 1
        return String(display.prefix(head)) + "…" + String(display.suffix(tail))
    }
}

/// Fixed-size info button in the custom title bar. It does not observe the
/// workspace (only the popover content does), so the title bar gains no
/// invalidation on the typing path.
struct WorkspaceRootInfoButton: View {
    let workspace: Workspace?
    let foregroundColor: Color
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(foregroundColor)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 18, height: 18)
        .opacity(workspace == nil ? 0 : 0.75)
        .disabled(workspace == nil)
        .safeHelp(String(localized: "workspaceRoot.button.help", defaultValue: "Workspace root"))
        .accessibilityLabel(String(localized: "workspaceRoot.button.help", defaultValue: "Workspace root"))
        .accessibilityIdentifier("WorkspaceRootInfoButton")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let workspace {
                WorkspaceRootPopover(workspace: workspace)
            }
        }
    }
}

/// Shows the root and the focused surface's cwd when it has drifted, with
/// change / adopt-focused / clear actions. Rows keep their height across
/// states so nothing jumps.
struct WorkspaceRootPopover: View {
    @ObservedObject var workspace: Workspace

    private var root: String? { workspace.rootDirectory }
    private var rootMissing: Bool { root != nil && !workspace.rootDirectoryExists }
    private var drifted: String? { WorkspaceRootActions.driftedFocusedDirectory(of: workspace) }

    private var rootText: String {
        guard let root else {
            return String(localized: "workspaceRoot.none", defaultValue: "No root set")
        }
        return WorkspaceRootActions.displayPath(root)
    }

    private var captionText: String {
        if rootMissing {
            return String(
                localized: "workspaceRoot.caption.missing",
                defaultValue: "This folder no longer exists. New terminals start in the focused surface's directory."
            )
        }
        if root == nil {
            return String(
                localized: "workspaceRoot.caption.none",
                defaultValue: "New terminals start in the focused surface's directory until a root is set."
            )
        }
        return String(
            localized: "workspaceRoot.caption",
            defaultValue: "New tabs, splits, and agents start here."
        )
    }

    private var driftText: String {
        let path = drifted.map(WorkspaceRootActions.displayPath) ?? ""
        return String(localized: "workspaceRoot.focusedSurface", defaultValue: "Focused surface: \(path)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "workspaceRoot.popover.title", defaultValue: "Workspace Root"))
                .font(.system(size: 13, weight: .semibold))

            Text(rootText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(root == nil ? .secondary : (rootMissing ? .orange : .primary))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("WorkspaceRootPath")

            // Reserved row: visible only when the focused cwd differs from the root.
            Text(driftText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(drifted == nil ? 0 : 1)
                .accessibilityHidden(drifted == nil)
                .accessibilityIdentifier("WorkspaceRootDrift")

            // Fixed two-line slot: the button row must not move when the
            // caption switches between its one- and two-line variants.
            Text(captionText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .topLeading)

            HStack(spacing: 8) {
                Button(String(localized: "workspaceRoot.change", defaultValue: "Change…")) {
                    WorkspaceRootActions.chooseRoot(for: workspace)
                }
                Button(String(localized: "workspaceRoot.useFocused", defaultValue: "Use Focused Directory")) {
                    WorkspaceRootActions.useFocusedDirectory(for: workspace)
                }
                .disabled(!WorkspaceRootActions.canUseFocusedDirectory(for: workspace))
                Spacer(minLength: 0)
                Button(String(localized: "workspaceRoot.clear", defaultValue: "Clear")) {
                    WorkspaceRootActions.clearRoot(for: workspace)
                }
                .disabled(root == nil)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 380)
    }
}
