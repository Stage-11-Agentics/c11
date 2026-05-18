import SwiftUI
import AppKit
import Foundation

/// Lightweight ring of working directories the operator has previously used
/// to spawn a workspace. Persisted in UserDefaults so the dialog can offer
/// quick re-pick without complicating the schema.
enum CreateWorkspaceRecents {
    static let key = "createWorkspace.recentDirectories"
    static let maxCount = 8

    static func load(defaults: UserDefaults = .standard) -> [String] {
        (defaults.array(forKey: key) as? [String]) ?? []
    }

    static func record(_ path: String, defaults: UserDefaults = .standard) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var list = load(defaults: defaults)
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        defaults.set(list, forKey: key)
    }
}

/// Modal shown when the operator triggers File → New Workspace (⌘N).
/// Replaces the prior auto-quad behavior: the user picks a working directory,
/// chooses a blueprint, and decides whether to auto-launch their configured
/// agent in the initial terminal pane. The chosen plan is handed back to the
/// AppDelegate, which runs it through `WorkspaceLayoutExecutor.apply`.
@MainActor
struct CreateWorkspaceSheet: View {
    struct Outcome {
        var workingDirectory: String
        var workspaceName: String
        var plan: WorkspaceApplyPlan
        var launchAgent: Bool
    }

    let initialDirectory: String
    let onCancel: () -> Void
    let onCreate: (Outcome) -> Void

    @State private var directory: String
    @State private var workspaceName: String = ""
    @State private var selectionId: String
    @State private var launchAgent: Bool = true
    @State private var entries: [BlueprintEntry] = []
    @State private var recentDirectories: [String] = []
    @State private var loadFailureMessage: String?
    @State private var submitting: Bool = false

    init(
        initialDirectory: String,
        onCancel: @escaping () -> Void,
        onCreate: @escaping (Outcome) -> Void
    ) {
        self.initialDirectory = initialDirectory
        _directory = State(initialValue: initialDirectory)
        // Seed entries + recents synchronously so the very first SwiftUI
        // layout pass reflects the full dialog height. Doing this in
        // .onAppear caused NSHostingController's preferredContentSize to
        // first publish the entries-empty size, then resize once entries
        // loaded — which read as a flash of a tiny dialog on prod builds.
        let seededEntries = Self.computeEntries(forDirectory: initialDirectory)
        _entries = State(initialValue: seededEntries)
        _recentDirectories = State(initialValue: CreateWorkspaceRecents.load())
        _selectionId = State(
            initialValue: seededEntries.first?.id ?? (BlueprintEntry.starterIds.first ?? "")
        )
        self.onCancel = onCancel
        self.onCreate = onCreate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            directorySection
            workspaceNameSection
            blueprintsSection
            footer
        }
        .padding(24)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(BrandColors.surfaceSwiftUI)
        .environment(\.colorScheme, .dark)
        .onAppear {
            reloadEntries()
            recentDirectories = CreateWorkspaceRecents.load()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "createWorkspace.title", defaultValue: "New Workspace"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)
            Text(String(
                localized: "createWorkspace.subtitle",
                defaultValue: "Pick a working directory and a blueprint to start from."
            ))
            .font(.system(size: 12))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.66))
        }
    }

    // MARK: - Directory

    private var directorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "createWorkspace.workingDirectory", defaultValue: "Working directory"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.62))
            HStack(spacing: 8) {
                TextField("", text: $directory)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Menu {
                    if recentDirectories.isEmpty {
                        Button(String(
                            localized: "createWorkspace.recentDirectories.empty",
                            defaultValue: "No recent directories yet"
                        )) {}
                        .disabled(true)
                    } else {
                        ForEach(recentDirectories, id: \.self) { path in
                            Button(displayPath(path)) {
                                directory = path
                            }
                        }
                    }
                } label: {
                    Label(
                        String(
                            localized: "createWorkspace.recentDirectories.label",
                            defaultValue: "Recent"
                        ),
                        systemImage: "clock"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .menuStyle(.button)
                .controlSize(.large)
                .fixedSize()
                .help(String(
                    localized: "createWorkspace.recentDirectories.help",
                    defaultValue: "Pick a recently-used directory"
                ))
                Button {
                    chooseDirectory()
                } label: {
                    Label(
                        String(localized: "createWorkspace.browse", defaultValue: "Browse…"),
                        systemImage: "folder"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Workspace name

    private var workspaceNameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "createWorkspace.name", defaultValue: "Workspace name"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.62))
            TextField(
                "",
                text: $workspaceName,
                prompt: Text(defaultWorkspaceName)
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.4))
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            Text(String(
                localized: "createWorkspace.name.hint",
                defaultValue: "Defaults to the directory name. Yours to override."
            ))
            .font(.system(size: 10))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.42))
        }
    }

    private var defaultWorkspaceName: String {
        let trimmed = directory.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Workspace" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let last = URL(fileURLWithPath: expanded).lastPathComponent
        return last.isEmpty ? "Workspace" : last
    }

    private var effectiveWorkspaceName: String {
        let trimmed = workspaceName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? defaultWorkspaceName : trimmed
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "createWorkspace.browse.panelTitle",
            defaultValue: "Choose Working Directory"
        )
        if !directory.isEmpty {
            let expanded = (directory as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
        }
    }

    // MARK: - Blueprints

    private var blueprintsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "createWorkspace.defaultLayouts", defaultValue: "Default layouts"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.62))

            VStack(spacing: 6) {
                ForEach(starterEntries) { entry in
                    blueprintRow(entry)
                }
            }

            agentToggle
                .padding(.top, 4)

            if !savedEntries.isEmpty {
                Text(String(
                    localized: "createWorkspace.customBlueprints",
                    defaultValue: "Custom blueprints"
                ))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.42))
                .padding(.top, 6)

                VStack(spacing: 6) {
                    ForEach(savedEntries) { entry in
                        blueprintRow(entry)
                    }
                }
            }

            if let loadFailureMessage {
                Text(loadFailureMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.5))
                    .padding(.top, 4)
            }
        }
    }

    private func blueprintRow(_ entry: BlueprintEntry) -> some View {
        let isSelected = entry.id == selectionId
        return Button {
            selectionId = entry.id
        } label: {
            HStack(spacing: 12) {
                BlueprintShapeIcon(shape: entry.shape, isSelected: isSelected)
                    .frame(width: 36, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BrandColors.whiteSwiftUI)
                    if let description = entry.description {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.6))
                            .lineLimit(2)
                    }
                }
                Spacer()
                if let badge = entry.sourceBadge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.42))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(BrandColors.ruleSwiftUI, lineWidth: 0.5)
                        )
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? BrandColors.goldFaintSwiftUI : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? BrandColors.goldSwiftUI : BrandColors.ruleSwiftUI,
                        lineWidth: isSelected ? 1 : 0.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var starterEntries: [BlueprintEntry] {
        entries.filter { $0.kind == .starter }
    }

    private var savedEntries: [BlueprintEntry] {
        entries.filter { $0.kind == .saved }
    }

    // MARK: - Agent toggle

    private var agentToggle: some View {
        Toggle(isOn: $launchAgent) {
            Text(String(
                localized: "createWorkspace.launchAgent",
                defaultValue: "Launch coding agent in initial pane"
            ))
            .font(.system(size: 12))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.86))
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "createWorkspace.create", defaultValue: "Create")) {
                submit()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
    }

    private var canSubmit: Bool {
        !submitting
            && !directory.trimmingCharacters(in: .whitespaces).isEmpty
            && entries.contains(where: { $0.id == selectionId })
    }

    private func submit() {
        guard !submitting else { return }
        guard let entry = entries.first(where: { $0.id == selectionId }) else { return }
        submitting = true
        let plan: WorkspaceApplyPlan
        do {
            plan = try entry.loadPlan()
        } catch {
            loadFailureMessage = String(
                format: String(
                    localized: "createWorkspace.loadFailed",
                    defaultValue: "Could not load blueprint: %@"
                ),
                "\(error)"
            )
            submitting = false
            return
        }
        let resolvedDir = (directory as NSString).expandingTildeInPath
        onCreate(Outcome(
            workingDirectory: resolvedDir,
            workspaceName: effectiveWorkspaceName,
            plan: plan,
            launchAgent: launchAgent
        ))
    }

    // MARK: - Loading

    private func reloadEntries() {
        let collected = Self.computeEntries(forDirectory: directory)
        entries = collected
        if !entries.contains(where: { $0.id == selectionId }) {
            selectionId = entries.first?.id ?? ""
        }
    }

    private static func computeEntries(forDirectory directory: String) -> [BlueprintEntry] {
        let store = WorkspaceBlueprintStore()
        let cwdURL: URL? = {
            let trimmed = directory.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }()
        let allIndex = store.merged(cwd: cwdURL)
        var collected: [BlueprintEntry] = []
        let starterDefs = BlueprintEntry.starterDefinitions
        for def in starterDefs {
            if let match = allIndex.first(where: { $0.name == def.fileName }) {
                collected.append(BlueprintEntry(
                    id: def.starterId,
                    kind: .starter,
                    label: def.label,
                    description: def.description,
                    shape: def.shape,
                    sourceBadge: nil,
                    loader: .index(match)
                ))
            }
        }
        let starterFileNames = Set(starterDefs.map(\.fileName))
        for index in allIndex where !starterFileNames.contains(index.name) {
            collected.append(BlueprintEntry(
                id: "saved:\(index.url)",
                kind: .saved,
                label: index.name,
                description: index.description,
                shape: .custom,
                sourceBadge: badge(for: index.source),
                loader: .index(index)
            ))
        }
        return collected
    }

    private static func badge(for source: WorkspaceBlueprintIndex.Source) -> String {
        switch source {
        case .repo:    return String(localized: "createWorkspace.badge.repo", defaultValue: "Repo")
        case .user:    return String(localized: "createWorkspace.badge.user", defaultValue: "User")
        case .builtIn: return String(localized: "createWorkspace.badge.builtIn", defaultValue: "Built-in")
        }
    }

}

// MARK: - Internal blueprint entry model

private struct BlueprintEntry: Identifiable {
    enum Kind { case starter, saved }
    enum Loader {
        case index(WorkspaceBlueprintIndex)
    }

    let id: String
    let kind: Kind
    let label: String
    let description: String?
    let shape: BlueprintShape
    let sourceBadge: String?
    let loader: Loader

    func loadPlan() throws -> WorkspaceApplyPlan {
        switch loader {
        case .index(let index):
            let url = URL(fileURLWithPath: index.url)
            let file = try WorkspaceBlueprintStore().read(url: url)
            return file.plan
        }
    }

    struct Definition {
        let starterId: String
        let label: String
        let description: String
        let fileName: String
        let shape: BlueprintShape
    }

    static let starterDefinitions: [Definition] = [
        Definition(
            starterId: "starter:one-column",
            label: String(localized: "createWorkspace.starter.oneColumn.label", defaultValue: "One column"),
            description: String(
                localized: "createWorkspace.starter.oneColumn.description",
                defaultValue: "Single terminal."
            ),
            fileName: "basic-terminal",
            shape: .oneColumn
        ),
        Definition(
            starterId: "starter:two-columns",
            label: String(localized: "createWorkspace.starter.twoColumns.label", defaultValue: "Two columns"),
            description: String(
                localized: "createWorkspace.starter.twoColumns.description",
                defaultValue: "Two terminals split side by side."
            ),
            fileName: "side-by-side",
            shape: .twoColumns
        ),
        Definition(
            starterId: "starter:quad",
            label: String(localized: "createWorkspace.starter.quad.label", defaultValue: "2x2 grid"),
            description: String(
                localized: "createWorkspace.starter.quad.description",
                defaultValue: "Four terminals in a 2x2 grid."
            ),
            fileName: "quad-terminal",
            shape: .quad
        ),
        Definition(
            starterId: "starter:six",
            label: String(localized: "createWorkspace.starter.six.label", defaultValue: "3x2 grid"),
            description: String(
                localized: "createWorkspace.starter.six.description",
                defaultValue: "Six terminals: three columns, two rows."
            ),
            fileName: "six-terminal",
            shape: .sixGrid
        ),
    ]

    static let starterIds: [String] = starterDefinitions.map(\.starterId)
}

// MARK: - Shape icon

private enum BlueprintShape {
    case oneColumn
    case twoColumns
    case quad
    case sixGrid
    case custom
}

private struct BlueprintShapeIcon: View {
    let shape: BlueprintShape
    let isSelected: Bool

    var body: some View {
        let stroke = isSelected ? BrandColors.goldSwiftUI : BrandColors.whiteSwiftUI.opacity(0.55)
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(stroke, lineWidth: 1)
                shapeOverlay(in: geo.size, color: stroke)
            }
        }
    }

    @ViewBuilder
    private func shapeOverlay(in size: CGSize, color: Color) -> some View {
        switch shape {
        case .oneColumn:
            EmptyView()
        case .twoColumns:
            Rectangle()
                .fill(color)
                .frame(width: 1, height: size.height)
        case .quad:
            ZStack {
                Rectangle()
                    .fill(color)
                    .frame(width: 1, height: size.height)
                Rectangle()
                    .fill(color)
                    .frame(width: size.width, height: 1)
            }
        case .sixGrid:
            ZStack {
                Rectangle()
                    .fill(color)
                    .frame(width: size.width, height: 1)
                Rectangle()
                    .fill(color)
                    .frame(width: 1, height: size.height)
                    .offset(x: -size.width / 6)
                Rectangle()
                    .fill(color)
                    .frame(width: 1, height: size.height)
                    .offset(x: size.width / 6)
            }
        case .custom:
            Rectangle()
                .fill(color.opacity(0.35))
                .frame(width: size.width * 0.4, height: 1)
        }
    }
}
