import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Recents data model

/// One entry in the recents ring. Persisted as JSON in UserDefaults so we can
/// carry richer metadata (open count, last-opened timestamp, pin state) than
/// the legacy `[String]` representation. The legacy key is migrated on first
/// load.
struct RecentDirectory: Codable, Equatable, Identifiable {
    var path: String
    var lastOpenedAt: Date
    var openCount: Int
    var pinned: Bool

    var id: String { path }

    var displayName: String {
        let expanded = (path as NSString).expandingTildeInPath
        let last = URL(fileURLWithPath: expanded).lastPathComponent
        return last.isEmpty ? path : last
    }
}

/// Persistent ring of working directories the operator has previously used to
/// spawn a workspace, plus migration from the pre-C11-115 string-array key.
enum CreateWorkspaceRecents {
    static let storageKey = "createWorkspace.recents.v2"
    static let legacyKey  = "createWorkspace.recentDirectories"
    static let maxCount   = 50

    static func load(defaults: UserDefaults = .standard) -> [RecentDirectory] {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([RecentDirectory].self, from: data) {
            return Array(decoded.prefix(maxCount))
        }
        // Migrate from legacy string array.
        if let legacy = defaults.array(forKey: legacyKey) as? [String], !legacy.isEmpty {
            let now = Date()
            let migrated = legacy.enumerated().map { idx, p in
                RecentDirectory(
                    path: p,
                    lastOpenedAt: now.addingTimeInterval(TimeInterval(-idx)),
                    openCount: 1,
                    pinned: false
                )
            }
            save(migrated, defaults: defaults)
            defaults.removeObject(forKey: legacyKey)
            return migrated
        }
        return []
    }

    static func save(_ list: [RecentDirectory], defaults: UserDefaults = .standard) {
        let capped = Array(list.prefix(maxCount))
        if let data = try? JSONEncoder().encode(capped) {
            defaults.set(data, forKey: storageKey)
        }
    }

    static func record(_ path: String, defaults: UserDefaults = .standard) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var list = load(defaults: defaults)
        if let idx = list.firstIndex(where: { $0.path == trimmed }) {
            list[idx].lastOpenedAt = Date()
            list[idx].openCount += 1
        } else {
            list.insert(
                RecentDirectory(path: trimmed, lastOpenedAt: Date(), openCount: 1, pinned: false),
                at: 0
            )
        }
        save(list, defaults: defaults)
    }

    static func togglePin(_ path: String, defaults: UserDefaults = .standard) {
        var list = load(defaults: defaults)
        guard let idx = list.firstIndex(where: { $0.path == path }) else { return }
        list[idx].pinned.toggle()
        save(list, defaults: defaults)
    }
}

/// Globally-remembered last-picked blueprint id. Pre-selects on next sheet
/// open so power users don't keep re-picking their preferred layout.
enum CreateWorkspaceLastLayout {
    static let key = "createWorkspace.lastBlueprintId"

    static func load(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    static func save(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: key)
    }
}

enum RecentsSort: String, CaseIterable {
    case recent
    case opened

    var label: String {
        switch self {
        case .recent:
            return String(localized: "createWorkspace.recents.sort.recent",
                          defaultValue: "Most recent")
        case .opened:
            return String(localized: "createWorkspace.recents.sort.opened",
                          defaultValue: "Most opened")
        }
    }

    func toggle() -> RecentsSort { self == .recent ? .opened : .recent }
}

/// Modal shown when the operator triggers File → New Workspace (⌘N).
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
    @State private var recents: [RecentDirectory] = []
    @State private var recentsSort: RecentsSort = .recent
    @State private var keyboardSelectedRecentIdx: Int = -1
    @State private var loadFailureMessage: String?
    @State private var submitting: Bool = false
    @State private var helpPopoverOpen: Bool = false
    @State private var isDropTargeted: Bool = false

    init(
        initialDirectory: String,
        onCancel: @escaping () -> Void,
        onCreate: @escaping (Outcome) -> Void
    ) {
        self.initialDirectory = initialDirectory
        _directory = State(initialValue: initialDirectory)
        let seededEntries = Self.computeEntries(forDirectory: initialDirectory)
        _entries = State(initialValue: seededEntries)
        _recents = State(initialValue: CreateWorkspaceRecents.load())
        let savedLast = CreateWorkspaceLastLayout.load()
        let initial: String
        if let savedLast, seededEntries.contains(where: { $0.id == savedLast }) {
            initial = savedLast
        } else {
            initial = seededEntries.first?.id ?? (BlueprintEntry.starterIds.first ?? "")
        }
        _selectionId = State(initialValue: initial)
        self.onCancel = onCancel
        self.onCreate = onCreate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            baseDirectorySection
            workspaceNameSection
            layoutsSection
            footer
        }
        .padding(24)
        .frame(width: 720)
        .fixedSize(horizontal: false, vertical: true)
        .background(BrandColors.surfaceSwiftUI)
        .environment(\.colorScheme, .dark)
        .onAppear {
            reloadEntries()
            recents = CreateWorkspaceRecents.load()
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

    // MARK: - Base directory (path + recents, tied together)

    private var baseDirectorySection: some View {
        VStack(spacing: 0) {
            // Header: title + path input + Browse
            VStack(alignment: .leading, spacing: 10) {
                Text(String(
                    localized: "createWorkspace.baseDirectory.label",
                    defaultValue: "Base directory for your new workspace"
                ))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)

                HStack(spacing: 8) {
                    TextField("", text: $directory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
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
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [BrandColors.whiteSwiftUI.opacity(0.02), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(BrandColors.ruleSwiftUI)
                    .frame(height: 1)
            }

            if recents.isEmpty {
                recentsEmptyState
            } else {
                recentsCaption
                recentsList
                recentsFooter
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(BrandColors.surface2SwiftUI)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isDropTargeted ? BrandColors.goldSwiftUI : BrandColors.ruleSwiftUI,
                    lineWidth: 1
                )
        )
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .fill(BrandColors.surfaceSwiftUI.opacity(0.78))
                    .overlay(
                        Text(String(
                            localized: "createWorkspace.dropTarget",
                            defaultValue: "Drop folder to set base directory"
                        ))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrandColors.goldSwiftUI)
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .focusable()
        .onKeyPress(.upArrow) { handleArrow(delta: -1) }
        .onKeyPress(.downArrow) { handleArrow(delta: +1) }
        .onKeyPress(.return) { handleReturn() }
    }

    private var recentsCaption: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(BrandColors.ruleSwiftUI)
                .frame(height: 1)
            Text(String(
                localized: "createWorkspace.recents.caption",
                defaultValue: "or select from your recent directories:"
            ))
            .font(.system(size: 11))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.55))
            Rectangle()
                .fill(BrandColors.ruleSwiftUI)
                .frame(height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(BrandColors.surfaceSwiftUI.opacity(0.18))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BrandColors.ruleSwiftUI)
                .frame(height: 1)
        }
    }

    private var recentsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(sortedRecents().enumerated()), id: \.element.id) { idx, r in
                        RecentRow(
                            recent: r,
                            isKeyboardFocused: idx == keyboardSelectedRecentIdx,
                            onClick: { selectRecent(r) },
                            onDoubleClick: { openRecent(r) },
                            onTogglePin: { togglePin(r) }
                        )
                        .id(r.id)
                    }
                }
            }
            .frame(maxHeight: 270)
            .onChange(of: keyboardSelectedRecentIdx) { _, newValue in
                let arr = sortedRecents()
                guard newValue >= 0, newValue < arr.count else { return }
                proxy.scrollTo(arr[newValue].id, anchor: .center)
            }
        }
    }

    private var recentsFooter: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(String(localized: "createWorkspace.recents.hint.click", defaultValue: "Click or"))
                kbdGlyph("↑↓")
                Text(String(localized: "createWorkspace.recents.hint.toSelect", defaultValue: "to select"))
                Text("·").foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.3))
                kbdGlyph("⏎")
                Text(String(
                    localized: "createWorkspace.recents.hint.openHint",
                    defaultValue: "or double-click opens with your last layout"
                ))
            }
            .font(.system(size: 11))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
            Spacer()
            Button {
                recentsSort = recentsSort.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(recentsSort.label)
                        .font(.system(size: 11))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(BrandColors.surface3SwiftUI)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(BrandColors.ruleSwiftUI, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(BrandColors.surfaceSwiftUI.opacity(0.18))
    }

    private var recentsEmptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        BrandColors.whiteSwiftUI.opacity(0.30),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
            }
            .frame(width: 38, height: 38)
            Text(String(
                localized: "createWorkspace.recents.empty.title",
                defaultValue: "No recent directories yet"
            ))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(BrandColors.whiteSwiftUI)
            Text(String(
                localized: "createWorkspace.recents.empty.hint",
                defaultValue: "Pick a directory above, browse to one, or drag a folder here."
            ))
            .font(.system(size: 11))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    @ViewBuilder
    private func kbdGlyph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.78))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(BrandColors.surface3SwiftUI)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(BrandColors.ruleSwiftUI, lineWidth: 0.5)
            )
    }

    private func sortedRecents() -> [RecentDirectory] {
        let pinned = recents.filter { $0.pinned }
        let unpinned = recents.filter { !$0.pinned }
        let sortFn: (RecentDirectory, RecentDirectory) -> Bool = {
            switch recentsSort {
            case .recent: return { $0.lastOpenedAt > $1.lastOpenedAt }
            case .opened: return { $0.openCount > $1.openCount }
            }
        }()
        return pinned.sorted(by: sortFn) + unpinned.sorted(by: sortFn)
    }

    private func selectRecent(_ r: RecentDirectory) {
        directory = r.path
        if let idx = sortedRecents().firstIndex(where: { $0.id == r.id }) {
            keyboardSelectedRecentIdx = idx
        }
    }

    private func openRecent(_ r: RecentDirectory) {
        directory = r.path
        submit()
    }

    private func togglePin(_ r: RecentDirectory) {
        CreateWorkspaceRecents.togglePin(r.path)
        recents = CreateWorkspaceRecents.load()
    }

    private func handleArrow(delta: Int) -> KeyPress.Result {
        let arr = sortedRecents()
        guard !arr.isEmpty else { return .ignored }
        var next = keyboardSelectedRecentIdx + delta
        if keyboardSelectedRecentIdx < 0 { next = delta > 0 ? 0 : arr.count - 1 }
        next = max(0, min(arr.count - 1, next))
        keyboardSelectedRecentIdx = next
        directory = arr[next].path
        return .handled
    }

    private func handleReturn() -> KeyPress.Result {
        let arr = sortedRecents()
        if keyboardSelectedRecentIdx >= 0, keyboardSelectedRecentIdx < arr.count {
            openRecent(arr[keyboardSelectedRecentIdx])
            return .handled
        }
        return .ignored
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                   isDir.boolValue {
                    directory = url.path
                }
            }
        }
        return true
    }

    // MARK: - Workspace name

    private var workspaceNameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "createWorkspace.name", defaultValue: "Workspace name"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)
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
                defaultValue: "Defaults to the directory name. Override to give this workspace a custom label."
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

    // MARK: - Layouts (one consolidated row: defaults + custom blueprints)

    private var layoutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(localized: "createWorkspace.layouts", defaultValue: "Layouts"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandColors.whiteSwiftUI)
                Button {
                    helpPopoverOpen.toggle()
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(
                    localized: "createWorkspace.customBlueprints.helpHint",
                    defaultValue: "What is a custom blueprint?"
                ))
                .popover(isPresented: $helpPopoverOpen, arrowEdge: .top) {
                    helpPopoverContent
                }
                Spacer()
            }

            DragScrollView {
                HStack(spacing: 12) {
                    ForEach(starterEntries) { entry in
                        blueprintCard(entry, showLetters: true)
                    }
                    if !savedEntries.isEmpty {
                        Rectangle()
                            .fill(BrandColors.ruleSwiftUI)
                            .frame(width: 1, height: 130)
                            .padding(.horizontal, 4)
                    }
                    ForEach(savedEntries) { entry in
                        blueprintCard(entry, showLetters: false)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .frame(height: 200)

            HStack(spacing: 12) {
                Spacer()
                legendBadge("A", String(localized: "createWorkspace.legend.agent", defaultValue: "agent"))
                legendBadge("T", String(localized: "createWorkspace.legend.terminal", defaultValue: "terminal"))
                legendBadge("B", String(localized: "createWorkspace.legend.browser", defaultValue: "browser"))
                legendBadge("M", String(localized: "createWorkspace.legend.markdown", defaultValue: "markdown"))
            }

            if let loadFailureMessage {
                Text(loadFailureMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.5))
            }
        }
    }

    @ViewBuilder
    private func legendBadge(_ letter: String, _ word: String) -> some View {
        HStack(spacing: 4) {
            Text(letter)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.85))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(BrandColors.surface3SwiftUI)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(BrandColors.ruleSwiftUI, lineWidth: 0.5)
                )
            Text(word)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.5))
        }
    }

    private var helpPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "createWorkspace.customBlueprints.help.body1",
                defaultValue: "Saved pane and surface layouts you can launch a workspace from."
            ))
            Text(String(
                localized: "createWorkspace.customBlueprints.help.body2",
                defaultValue: "c11 is agent-first software, so we didn't build a UI to make these. Just ask your agent. It can write a blueprint file to your blueprints folder, and it'll show up here."
            ))
            Button {
                revealBlueprintsFolder()
            } label: {
                Label(
                    String(
                        localized: "createWorkspace.customBlueprints.help.reveal",
                        defaultValue: "Reveal blueprints folder"
                    ),
                    systemImage: "folder"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.system(size: 12))
        .frame(width: 320)
        .padding(14)
    }

    private func revealBlueprintsFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".config/c11/blueprints", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Blueprint card (shared by default + custom)

    @ViewBuilder
    private func blueprintCard(_ entry: BlueprintEntry, showLetters: Bool) -> some View {
        let isSelected = entry.id == selectionId
        VStack(alignment: .center, spacing: 10) {
            if showLetters, let topology = entry.shape.letterTopology {
                LetterCellIcon(topology: topology)
                    .frame(width: 132, height: 78)
            } else {
                OutlineShapeIcon(shape: entry.shape)
                    .frame(width: 132, height: 78)
            }
            Text(entry.label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
            if let description = entry.description {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 176, height: 168, alignment: .top)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? BrandColors.goldFaintSwiftUI : BrandColors.surface2SwiftUI)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? BrandColors.goldSwiftUI : BrandColors.ruleSwiftUI,
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        // Mirror the RecentRow gesture composition: single-click selects,
        // double-click selects and submits. A SwiftUI Button swallows the
        // second click, so the card is a plain View with composed taps.
        .gesture(
            TapGesture(count: 2).onEnded {
                selectionId = entry.id
                CreateWorkspaceLastLayout.save(entry.id)
                submit()
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                selectionId = entry.id
                CreateWorkspaceLastLayout.save(entry.id)
            }
        )
    }

    private var starterEntries: [BlueprintEntry] {
        entries.filter { $0.kind == .starter }
    }

    private var savedEntries: [BlueprintEntry] {
        entries.filter { $0.kind == .saved }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Toggle(isOn: $launchAgent) {
                Text(String(
                    localized: "createWorkspace.launchAgent",
                    defaultValue: "Launch your default coding agent in the first pane"
                ))
                .font(.system(size: 11))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.75))
            }
            .toggleStyle(.checkbox)
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
        CreateWorkspaceLastLayout.save(entry.id)
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
            if let savedLast = CreateWorkspaceLastLayout.load(),
               entries.contains(where: { $0.id == savedLast }) {
                selectionId = savedLast
            } else {
                selectionId = entries.first?.id ?? ""
            }
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

// MARK: - Recent row

private struct RecentRow: View {
    let recent: RecentDirectory
    let isKeyboardFocused: Bool
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    let onTogglePin: () -> Void

    @State private var hovering: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recent.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BrandColors.whiteSwiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(displayPath(recent.path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(relativeTime(recent.lastOpenedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.55))
                Text(openCountLabel(recent.openCount))
                    .font(.system(size: 10))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.35))
            }
            Button {
                onTogglePin()
            } label: {
                Image(systemName: recent.pinned ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(recent.pinned
                                     ? BrandColors.goldSwiftUI
                                     : BrandColors.whiteSwiftUI.opacity(hovering ? 0.85 : 0.55))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(recent.pinned
                  ? String(localized: "createWorkspace.recents.unpin", defaultValue: "Unpin")
                  : String(localized: "createWorkspace.recents.pin", defaultValue: "Pin to top"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Rectangle()
                .fill(rowBackground)
        )
        .overlay(alignment: .leading) {
            if isKeyboardFocused {
                Rectangle()
                    .fill(BrandColors.goldSwiftUI)
                    .frame(width: 2)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BrandColors.ruleSwiftUI)
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            TapGesture(count: 2).onEnded { onDoubleClick() }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded { onClick() }
        )
    }

    private var rowBackground: Color {
        if isKeyboardFocused {
            return BrandColors.goldFaintSwiftUI
        }
        if hovering {
            return BrandColors.whiteSwiftUI.opacity(0.03)
        }
        return .clear
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func relativeTime(_ date: Date) -> String {
        let delta = -date.timeIntervalSinceNow
        if delta < 60 {
            return String(localized: "createWorkspace.recents.justNow", defaultValue: "just now")
        }
        let m = Int(delta / 60)
        if m < 60 { return String(format: "%dm ago", m) }
        let h = m / 60
        if h < 24 { return String(format: "%dh ago", h) }
        let d = h / 24
        if d < 7 { return String(format: "%dd ago", d) }
        let w = d / 7
        if w < 5 { return String(format: "%dw ago", w) }
        let mo = d / 30
        return String(format: "%dmo ago", mo)
    }

    private func openCountLabel(_ n: Int) -> String {
        if n == 1 {
            return String(localized: "createWorkspace.recents.openedOnce",
                          defaultValue: "opened 1 time")
        }
        return String(
            format: String(
                localized: "createWorkspace.recents.openedMany",
                defaultValue: "opened %d times"
            ),
            n
        )
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
            label: String(localized: "createWorkspace.starter.single.label", defaultValue: "Single"),
            description: String(
                localized: "createWorkspace.starter.single.description",
                defaultValue: "One terminal pane filling the workspace."
            ),
            fileName: "basic-terminal",
            shape: .oneColumn
        ),
        Definition(
            starterId: "starter:two-columns",
            label: String(localized: "createWorkspace.starter.twoColumns.label", defaultValue: "Two columns"),
            description: String(
                localized: "createWorkspace.starter.twoColumns.description",
                defaultValue: "Two terminals split side by side. Agent left, terminal right."
            ),
            fileName: "side-by-side",
            shape: .twoColumns
        ),
        Definition(
            starterId: "starter:quad",
            label: String(localized: "createWorkspace.starter.quad.label", defaultValue: "2 × 2"),
            description: String(
                localized: "createWorkspace.starter.quad.description",
                defaultValue: "Four terminal panes in a 2 × 2 grid. Agent in the top-left."
            ),
            fileName: "quad-terminal",
            shape: .quad
        ),
        Definition(
            starterId: "starter:two-by-three",
            label: String(localized: "createWorkspace.starter.twoByThree.label", defaultValue: "2 × 3"),
            description: String(
                localized: "createWorkspace.starter.twoByThree.description",
                defaultValue: "Six terminal panes in 2 columns, 3 rows. External 27-inch+ monitor suggested."
            ),
            fileName: "two-by-three",
            shape: .twoByThree
        ),
    ]

    static let starterIds: [String] = starterDefinitions.map(\.starterId)
}

// MARK: - Shape model

enum BlueprintShape {
    case oneColumn
    case twoColumns
    case quad
    case twoByThree
    case custom

    /// Returns the cell topology (rows of letter cells) for default-layout
    /// icons. Custom blueprints return nil and are rendered with the
    /// outline-only fallback.
    var letterTopology: LetterTopology? {
        switch self {
        case .oneColumn:
            return LetterTopology(rows: [["A"]])
        case .twoColumns:
            return LetterTopology(rows: [["A", "T"]])
        case .quad:
            return LetterTopology(rows: [
                ["A", "T"],
                ["T", "T"],
            ])
        case .twoByThree:
            return LetterTopology(rows: [
                ["A", "T"],
                ["T", "T"],
                ["T", "T"],
            ])
        case .custom:
            return nil
        }
    }
}

struct LetterTopology {
    let rows: [[String]]
}

// MARK: - Letter-cell icon (default layouts)

private struct LetterCellIcon: View {
    let topology: LetterTopology

    var body: some View {
        let stroke = BrandColors.whiteSwiftUI.opacity(0.55)
        VStack(spacing: 1) {
            ForEach(Array(topology.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 1) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, letter in
                        ZStack {
                            Rectangle()
                                .fill(BrandColors.surface2SwiftUI)
                            Text(letter)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(stroke)
                        }
                    }
                }
            }
        }
        .background(stroke)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(stroke, lineWidth: 0.5)
        )
    }
}

// MARK: - Outline-only icon (custom blueprints)

private struct OutlineShapeIcon: View {
    let shape: BlueprintShape

    var body: some View {
        let stroke = BrandColors.whiteSwiftUI.opacity(0.55)
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(stroke, lineWidth: 1)
                Rectangle()
                    .fill(stroke.opacity(0.45))
                    .frame(width: geo.size.width * 0.4, height: 1)
            }
        }
    }
}

// MARK: - Brand color shims

extension BrandColors {
    static var surface2SwiftUI: Color { Color(red: 0.12, green: 0.12, blue: 0.135) }
    static var surface3SwiftUI:  Color { Color(red: 0.175, green: 0.175, blue: 0.196) }
}

// MARK: - Horizontal scroll with click-and-drag

/// Horizontal scroll container that supports click-and-drag panning alongside
/// trackpad/scroll-wheel gestures. The drag handling uses an application-level
/// NSEvent monitor (more robust than NSPanGestureRecognizer, which has been
/// observed to wedge after a scroll-wheel event interrupts its state machine).
/// A visible horizontal scrollbar is always shown so the affordance is
/// explicit even before the user attempts to scroll.
private struct DragScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        if let documentView = scrollView.documentView, let contentView = scrollView.contentView as NSClipView? {
            NSLayoutConstraint.activate([
                documentView.topAnchor.constraint(equalTo: contentView.topAnchor),
                documentView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                documentView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            ])
        }

        context.coordinator.scrollView = scrollView
        context.coordinator.installMonitor()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let hosting = nsView.documentView as? NSHostingView<Content> {
            hosting.rootView = content
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        private var monitor: Any?
        private var pressLocation: NSPoint?
        private var lastLocation: NSPoint?
        private var didPan = false
        private let threshold: CGFloat = 4

        deinit { removeMonitor() }

        func removeMonitor() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self else { return event }
                return self.process(event)
            }
        }

        private func process(_ event: NSEvent) -> NSEvent? {
            guard let sv = scrollView,
                  let window = sv.window,
                  event.window === window else {
                return event
            }
            let pointInSv = sv.convert(event.locationInWindow, from: nil)
            let inside = sv.bounds.contains(pointInSv)

            switch event.type {
            case .leftMouseDown:
                if inside {
                    pressLocation = event.locationInWindow
                    lastLocation = event.locationInWindow
                    didPan = false
                } else {
                    pressLocation = nil
                    lastLocation = nil
                    didPan = false
                }
                return event

            case .leftMouseDragged:
                guard let start = pressLocation, let last = lastLocation else {
                    return event
                }
                let dx = event.locationInWindow.x - start.x
                let dy = event.locationInWindow.y - start.y
                if !didPan && hypot(dx, dy) > threshold {
                    didPan = true
                }
                if didPan {
                    let stepDx = event.locationInWindow.x - last.x
                    let origin = sv.contentView.bounds.origin
                    let docWidth = sv.documentView?.bounds.width ?? 0
                    let viewWidth = sv.contentView.bounds.width
                    let maxX = max(0, docWidth - viewWidth)
                    let nextX = min(maxX, max(0, origin.x - stepDx))
                    sv.contentView.scroll(to: NSPoint(x: nextX, y: origin.y))
                    sv.reflectScrolledClipView(sv.contentView)
                    lastLocation = event.locationInWindow
                    return nil
                }
                return event

            case .leftMouseUp:
                let panned = didPan
                pressLocation = nil
                lastLocation = nil
                didPan = false
                return panned ? nil : event

            default:
                return event
            }
        }
    }
}
