import SwiftUI
import Combine

// MARK: - Seam types (C11-182 ↔ C11-181)
//
// The A-button popover (C11-181, parallel sibling) opens this editor via
// `AppDelegate.openAgentConfigEditor(focus:origin:)`, which posts the request
// below. `‹Back`/Esc posts the closed request so the popover can reopen as the
// single visible surface. Defined here because this file owns the editor.

/// What the editor opens onto.
enum AgentConfigEditorFocus: Equatable {
    /// Edit the saved config with this id.
    case config(String)
    /// Start a new config.
    case new
    /// Open the launch-stats view.
    case stats
}

/// Where an open request came from, so close can restore the right surface.
enum AgentConfigEditorOrigin: String {
    /// Opened from the Settings Saved Configs subsection (stays put on close).
    case settings
    /// Opened from the A-button popover (close orders Settings out + reopens the popover).
    case popover
}

/// The NotificationCenter seam that carries open/close requests across windows.
enum AgentConfigEditorRequest {
    static let openName = Notification.Name("c11.agentConfigEditor.open")
    static let closedName = Notification.Name("c11.agentConfigEditor.closed")

    private static let focusKindKey = "focusKind"   // "config" | "new" | "stats"
    private static let focusIdKey = "focusId"       // config id for .config
    private static let originKey = "origin"
    private static let returnToPopoverKey = "returnToPopover"

    static func postOpen(focus: AgentConfigEditorFocus, origin: AgentConfigEditorOrigin) {
        var info: [String: Any] = [originKey: origin.rawValue]
        switch focus {
        case .config(let id): info[focusKindKey] = "config"; info[focusIdKey] = id
        case .new:            info[focusKindKey] = "new"
        case .stats:          info[focusKindKey] = "stats"
        }
        NotificationCenter.default.post(name: openName, object: nil, userInfo: info)
    }

    static func focus(from note: Notification) -> AgentConfigEditorFocus {
        switch note.userInfo?[focusKindKey] as? String {
        case "config":
            if let id = note.userInfo?[focusIdKey] as? String { return .config(id) }
            return .new
        case "stats": return .stats
        default:      return .new
        }
    }

    static func origin(from note: Notification) -> AgentConfigEditorOrigin {
        (note.userInfo?[originKey] as? String).flatMap(AgentConfigEditorOrigin.init) ?? .settings
    }

    /// Post the close request. `returnToPopover` is true only when the operator
    /// backed out (Back/Esc) from a popover-origin session — never after a launch.
    static func postClosed(returnToPopover: Bool) {
        NotificationCenter.default.post(
            name: closedName, object: nil,
            userInfo: [returnToPopoverKey: returnToPopover]
        )
    }

    static func shouldReturnToPopover(from note: Notification) -> Bool {
        note.userInfo?[returnToPopoverKey] as? Bool ?? false
    }
}

// MARK: - Installed probe (design §5.6)

/// Best-effort "is this harness's binary on PATH" probe. A Finder-launched GUI
/// app inherits launchd's minimal PATH, so we resolve the operator's real PATH
/// once per app session via their login shell, cache it, and answer off the
/// render path. **Degrade-never-block:** any failure (no shell, timeout, empty
/// capture) resolves to `installed = true`, so the editor never wrongly greys a
/// working harness (the launch still degrades to the shell's own error, §5.6).
@MainActor
final class AgentInstalledProbe: ObservableObject {
    static let shared = AgentInstalledProbe()

    /// Per-harness installed verdict, computed once when the PATH resolves. An
    /// absent key = unresolved (treat as installed); the render path only reads
    /// this dict, never the filesystem.
    @Published private(set) var verdicts: [String: Bool] = [:]
    private var didStart = false

    /// Kick the async login-shell PATH capture + verdict computation once. Safe
    /// to call repeatedly.
    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        Task.detached(priority: .utility) {
            let dirs = Self.captureLoginShellPath()
            let verdicts = Self.computeVerdicts(pathDirs: dirs)
            await MainActor.run { self.verdicts = verdicts }
        }
    }

    /// Whether the harness's binary resolves on the captured PATH. Returns `true`
    /// while the PATH is still resolving or on any failure (degrade-never-block).
    /// A pure dictionary read — no filesystem stat on the render path.
    func isInstalled(harness: String) -> Bool {
        verdicts[harness] ?? true
    }

    /// Stat each harness's binary against the captured PATH once, off-main. An
    /// empty/unresolved PATH yields `[:]` so every harness reads as installed.
    private nonisolated static func computeVerdicts(pathDirs: [String]?) -> [String: Bool] {
        guard let dirs = pathDirs, !dirs.isEmpty else { return [:] }
        let fm = FileManager.default
        var out: [String: Bool] = [:]
        for type in AgentType.allCases {
            let command = AgentRegistry.shared.manifest(forKind: type.rawValue)?.factoryCommand ?? ""
            guard let bin = AgentConfigAxes.firstBinaryToken(command) else { out[type.rawValue] = true; continue }
            if bin.contains("/") {
                out[type.rawValue] = fm.isExecutableFile(atPath: bin)
            } else {
                out[type.rawValue] = dirs.contains { fm.isExecutableFile(atPath: $0 + "/" + bin) }
            }
        }
        return out
    }

    /// Run the user's login shell once to capture their real PATH, killing it
    /// after a short deadline so a prompting rc file can't hang the task. Returns
    /// nil on any failure/timeout so callers degrade to "installed". `nonisolated`
    /// so the detached capture task can call it off the main actor.
    private nonisolated static func captureLoginShellPath() -> [String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if done.wait(timeout: .now() + 3.0) == .timedOut {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let dirs = raw.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return dirs.isEmpty ? nil : dirs
    }
}

// MARK: - Library view-model

/// Observable wrapper over `AgentConfigLibraryStore` for the SwiftUI surfaces.
/// Recompute-on-mutation: every mutator writes through the store (the file is
/// the contract) then reloads the published snapshot. Injectable store for tests.
@MainActor
final class AgentConfigLibraryViewModel: ObservableObject {
    @Published private(set) var configs: [SavedAgentConfig] = []
    @Published private(set) var defaultState: AgentConfigDefault =
        AgentConfigLibraryFile.factory.default

    private let store: AgentConfigLibraryStore

    init(store: AgentConfigLibraryStore = .shared) {
        self.store = store
        reload()
    }

    func reload() {
        let file = store.current
        configs = file.configs.sorted { $0.order < $1.order }
        defaultState = file.default
    }

    func isPinnedDefault(_ config: SavedAgentConfig) -> Bool {
        defaultState.mode == .pinned && defaultState.configId == config.id
    }

    var pinnedConfig: SavedAgentConfig? {
        configs.first { $0.id == defaultState.configId }
    }

    /// Save the draft (add when `sourceId == nil`, else update in place). Returns
    /// the stored config (with its resolved id), or nil on a store error.
    @discardableResult
    func save(_ draft: EditorDraft) -> SavedAgentConfig? {
        let name = draft.resolvedName
        do {
            if let id = draft.sourceId, let existing = configs.first(where: { $0.id == id }) {
                let updated = SavedAgentConfig(id: id, name: name, order: existing.order, config: draft.config)
                var file = store.current
                if let i = file.configs.firstIndex(where: { $0.id == id }) {
                    file.configs[i] = updated
                    try store.write(file)
                }
                reload()
                return updated
            } else {
                let stored = try store.add(
                    SavedAgentConfig(id: "", name: name, order: 0, config: draft.config)
                )
                reload()
                return stored
            }
        } catch {
            return nil
        }
    }

    func remove(id: String) {
        try? store.remove(id: id)
        reload()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = configs
        ordered.move(fromOffsets: source, toOffset: destination)
        // Compose the new order once and write the whole file atomically, so a
        // mid-drop failure can never persist a partially-applied order.
        let orderById = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
        var file = store.current
        for i in file.configs.indices {
            if let newOrder = orderById[file.configs[i].id] { file.configs[i].order = newOrder }
        }
        try? store.write(file)
        reload()
    }

    func setDefault(id: String) {
        try? store.setDefault(configId: id)
        reload()
    }

    func setFollowRecent(_ on: Bool) {
        try? store.setMode(on ? .followRecent : .pinned)
        reload()
    }
}

// MARK: - Editor draft

/// The working copy of the config being edited (a value type SwiftUI can bind
/// against). `sourceId == nil` means a not-yet-saved new config.
struct EditorDraft: Equatable {
    var sourceId: String?
    var name: String
    var config: AgentLaunchConfig

    var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? AgentConfigAxes.autoName(for: config) : trimmed
    }

    static func new() -> EditorDraft {
        EditorDraft(sourceId: nil, name: "",
                    config: AgentLaunchConfig(harness: "claude-code",
                                              systemPrompt: SystemPromptSetting(mode: .inherit)))
    }

    static func from(_ saved: SavedAgentConfig) -> EditorDraft {
        EditorDraft(sourceId: saved.id, name: saved.name, config: saved.config)
    }
}

// MARK: - Editor sheet chrome tokens

private enum EditorTheme {
    static var goldGhost: Color { BrandColors.goldSwiftUI.opacity(0.10) }
    static var goldFaint: Color { BrandColors.goldFaintSwiftUI }
    static var rowRule: Color { BrandColors.ruleSwiftUI.opacity(0.55) }
    static let sheetWidth: CGFloat = 860
}

// MARK: - The editor sheet

/// Tier 2 of the model picker (design §5.4/§5.5): the Saved Configs editor +
/// launch stats view, reproduced from the binding prototype. Presented as a
/// `.sheet` from the Settings section.
struct AgentConfigEditorSheet: View {
    @ObservedObject var library: AgentConfigLibraryViewModel
    let initialFocus: AgentConfigEditorFocus
    /// Called when the operator closes the sheet; `returnToPopover` is true only
    /// on a Back/Esc backout (not after a launch).
    var onClose: (_ returnToPopover: Bool) -> Void

    @StateObject private var installed = AgentInstalledProbe.shared
    @State private var draft: EditorDraft = .new()
    @State private var statsMode = false
    @State private var advancedOpen = false
    @State private var modelFilter = ""
    @State private var savedFlashId: String?
    @State private var launchFeedback: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(BrandColors.ruleSwiftUI)
            HStack(spacing: 0) {
                libraryRail
                Divider().overlay(BrandColors.ruleSwiftUI)
                Group {
                    if statsMode {
                        LaunchStatsView()
                    } else {
                        editor
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if !statsMode {
                if let launchFeedback {
                    HStack {
                        Text(launchFeedback).font(.system(size: 10.5))
                            .foregroundStyle(BrandColors.goldSwiftUI)
                        Spacer()
                    }
                    .padding(.horizontal, 22).padding(.top, 6)
                }
                Divider().overlay(BrandColors.ruleSwiftUI)
                footer
            }
        }
        .frame(width: EditorTheme.sheetWidth)
        .frame(maxHeight: 640)
        .background(BrandColors.surfaceSwiftUI)
        .environment(\.colorScheme, .dark)
        .overlay(hiddenKeyboardCatchers)
        .onAppear { installed.startIfNeeded(); applyFocus(initialFocus) }
    }

    // Hidden buttons that catch Return (Save & Launch) and Escape (Back).
    private var hiddenKeyboardCatchers: some View {
        ZStack {
            Button("", action: backOut).keyboardShortcut(.cancelAction).hidden()
            if !statsMode {
                Button("", action: saveAndLaunch).keyboardShortcut(.defaultAction).hidden()
            }
        }
        .frame(width: 0, height: 0)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: backOut) {
                HStack(spacing: 5) {
                    Text("‹").font(.system(size: 13))
                    Text(String(localized: "agentConfigEditor.back", defaultValue: "Back"))
                }
                .font(.system(size: 11))
                .foregroundStyle(BrandColors.dimSwiftUI)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(BrandColors.ruleSwiftUI, lineWidth: 1))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(statsMode
                     ? String(localized: "agentConfigEditor.stats.title", defaultValue: "Launch Stats")
                     : String(localized: "agentConfigEditor.title", defaultValue: "Agent Configurations"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(BrandColors.whiteSwiftUI)
                Text(statsMode
                     ? String(localized: "agentConfigEditor.stats.subtitle",
                               defaultValue: "Every launch through any path appends to agent-launches.jsonl — these are lifetime numbers.")
                     : String(localized: "agentConfigEditor.subtitle",
                               defaultValue: "Every saved recipe layers over its harness's Settings — set a field to override, leave it to inherit."))
                    .font(.system(size: 11.5, weight: .light))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
    }

    // MARK: Library rail

    private var libraryRail: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "agentConfigEditor.savedConfigs", defaultValue: "Saved configs"))
                    .font(.system(size: 9.5, weight: .medium)).textCase(.uppercase)
                    .tracking(1.4).foregroundStyle(BrandColors.dimSwiftUI)
                Spacer()
                Text(String(localized: "agentConfigEditor.dragToReorder", defaultValue: "drag ⠿ to reorder"))
                    .font(.system(size: 9)).foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 7)

            List {
                ForEach(library.configs, id: \.id) { config in
                    libraryRow(config)
                        .listRowBackground(rowBackground(config))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                .onMove { library.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Button(action: newConfig) {
                HStack(spacing: 8) {
                    Text("＋").font(.system(size: 13))
                    Text(String(localized: "agentConfigEditor.newConfig", defaultValue: "New config"))
                        .font(.system(size: 11.5))
                    Spacer()
                }
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.65))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(BrandColors.ruleSwiftUI), alignment: .top)
        }
        .frame(width: 252)
        .background(BrandColors.surfaceSwiftUI.opacity(0.5))
    }

    private func libraryRow(_ config: SavedAgentConfig) -> some View {
        Button {
            selectConfig(config)
        } label: {
            HStack(spacing: 8) {
                Text("⠿").font(.system(size: 10)).foregroundStyle(BrandColors.dimSwiftUI)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text(config.name).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BrandColors.whiteSwiftUI)
                        if library.isPinnedDefault(config) {
                            Text("●").font(.system(size: 9)).foregroundStyle(BrandColors.goldSwiftUI)
                        }
                    }
                    Text(sublineText(config.config))
                        .font(.system(size: 9.5)).foregroundStyle(BrandColors.dimSwiftUI)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowBackground(_ config: SavedAgentConfig) -> Color {
        if !statsMode, draft.sourceId == config.id { return EditorTheme.goldFaint }
        if savedFlashId == config.id { return EditorTheme.goldFaint }
        return .clear
    }

    private func sublineText(_ config: AgentLaunchConfig) -> String {
        AgentConfigAxes.subline(config)
    }

    // MARK: Editor (imported from AgentConfigRecipeEditorContent to keep body small)

    private var editor: some View {
        AgentConfigRecipeEditor(
            draft: $draft,
            advancedOpen: $advancedOpen,
            modelFilter: $modelFilter,
            installed: installed
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(String(localized: "agentConfigEditor.default", defaultValue: "Default"))
                .font(.system(size: 9, weight: .medium)).textCase(.uppercase).tracking(1.2)
                .foregroundStyle(BrandColors.dimSwiftUI)
            Menu {
                ForEach(library.configs, id: \.id) { config in
                    Button(config.name) { library.setDefault(id: config.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("●").foregroundStyle(BrandColors.goldSwiftUI)
                    Text(library.pinnedConfig?.name
                         ?? String(localized: "agentConfigEditor.noDefault", defaultValue: "—"))
                        .foregroundStyle(BrandColors.whiteSwiftUI)
                    Text("▾").font(.system(size: 9)).foregroundStyle(BrandColors.dimSwiftUI)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(BrandColors.surface3SwiftUI)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton).fixedSize()

            Button {
                library.setFollowRecent(library.defaultState.mode != .followRecent)
            } label: {
                HStack(spacing: 6) {
                    checkbox(on: library.defaultState.mode == .followRecent)
                    Text(String(localized: "agentConfigEditor.followRecent", defaultValue: "follow most recent"))
                        .font(.system(size: 10.5)).foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button(String(localized: "agentConfigEditor.save", defaultValue: "Save"), action: saveOnly)
                .buttonStyle(.bordered)
            Button(action: saveAndLaunch) {
                HStack(spacing: 8) {
                    Text(String(localized: "agentConfigEditor.saveLaunch", defaultValue: "Save & Launch"))
                    Text("\u{23CE}").opacity(0.55).font(.system(size: 11))
                }
            }
            .buttonStyle(GoldCTAButtonStyle())
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(BrandColors.surfaceSwiftUI.opacity(0.6))
    }

    private func checkbox(on: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(on ? BrandColors.goldSwiftUI : Color.clear)
                .frame(width: 13, height: 13)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? BrandColors.goldSwiftUI : BrandColors.dimSwiftUI, lineWidth: 1))
            if on { Text("✓").font(.system(size: 9)).foregroundStyle(BrandColors.blackSwiftUI) }
        }
    }

    // MARK: Actions

    private func applyFocus(_ focus: AgentConfigEditorFocus) {
        switch focus {
        case .config(let id):
            if let match = library.configs.first(where: { $0.id == id }) { selectConfig(match) }
            else { newConfig() }
        case .new:
            newConfig()
        case .stats:
            statsMode = true
        }
    }

    private func selectConfig(_ config: SavedAgentConfig) {
        statsMode = false
        draft = .from(config)
        advancedOpen = false
        modelFilter = ""
        launchFeedback = nil
    }

    private func newConfig() {
        statsMode = false
        draft = .new()
        advancedOpen = false
        modelFilter = ""
        launchFeedback = nil
    }

    private func saveOnly() {
        launchFeedback = nil
        guard let saved = library.save(draft) else { return }
        draft.sourceId = saved.id
        flashSaved(saved.id)
    }

    private func saveAndLaunch() {
        guard !statsMode, let saved = library.save(draft) else { return }
        draft.sourceId = saved.id
        // Never silently no-op (design MINOR-5): keep the sheet open + explain
        // when there is nothing to launch into or the recipe has no command.
        switch AppDelegate.shared?.launchSavedAgentConfig(saved) ?? .noWorkspace {
        case .launched:
            onClose(false) // launched — do not return to the popover
        case .noWorkspace:
            flashSaved(saved.id)
            launchFeedback = String(localized: "agentConfigEditor.launch.noWorkspace",
                                    defaultValue: "Saved. No workspace open to launch into — open one, then launch.")
        case .emptyCommand:
            flashSaved(saved.id)
            launchFeedback = String(localized: "agentConfigEditor.launch.emptyCommand",
                                    defaultValue: "Saved. This recipe has no command to launch — set one under Advanced.")
        }
    }

    private func backOut() {
        onClose(true)
    }

    private func flashSaved(_ id: String) {
        savedFlashId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            if savedFlashId == id { savedFlashId = nil }
        }
    }
}

// MARK: - Recipe editor (axis-dependency order, design §5.4)

/// The right-hand recipe editor: harness → model → effort → system prompt →
/// advanced, each overridable field carrying an inherit/override state chip.
struct AgentConfigRecipeEditor: View {
    @Binding var draft: EditorDraft
    @Binding var advancedOpen: Bool
    @Binding var modelFilter: String
    @ObservedObject var installed: AgentInstalledProbe

    private var harness: String { draft.config.harness }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                nameField
                harnessField
                modelField
                effortField
                systemPromptField
                advancedField
            }
            .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 18)
        }
    }

    // MARK: Field chrome

    private func fieldLabel(_ text: String, trailing: AnyView? = nil) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 10, weight: .medium)).textCase(.uppercase).tracking(1.2)
                .foregroundStyle(BrandColors.dimSwiftUI)
            if let trailing { trailing }
        }
    }

    private func overrideChip(_ isOverride: Bool) -> AnyView {
        AnyView(
            Text(isOverride
                 ? String(localized: "agentConfigEditor.override", defaultValue: "● override")
                 : String(localized: "agentConfigEditor.inherits", defaultValue: "○ inherits harness Settings"))
                .font(.system(size: 9, weight: isOverride ? .regular : .light))
                .foregroundStyle(isOverride ? BrandColors.goldSwiftUI : Color(white: 0.29))
        )
    }

    private var textFieldFill: some View {
        RoundedRectangle(cornerRadius: 6).fill(BrandColors.surface2SwiftUI)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(BrandColors.ruleSwiftUI, lineWidth: 1))
    }

    // MARK: Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(String(localized: "agentConfigEditor.name", defaultValue: "Name"))
            TextField(AgentConfigAxes.autoName(for: draft.config), text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(BrandColors.whiteSwiftUI)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(textFieldFill)
        }
    }

    // MARK: Harness grid

    private var harnessField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(String(localized: "agentConfigEditor.harness", defaultValue: "Harness"),
                       trailing: AnyView(
                        Text(String(localized: "agentConfigEditor.harness.hint",
                                    defaultValue: "the root axis — gates everything below"))
                            .font(.system(size: 9, weight: .light)).foregroundStyle(Color(white: 0.29))))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                ForEach(AgentType.allCases) { type in
                    harnessCard(type)
                }
            }
        }
    }

    private func harnessCard(_ type: AgentType) -> some View {
        let k = type.rawValue
        let isSel = harness == k
        let isInstalled = installed.isInstalled(harness: k)
        return Button {
            draft.config = AgentConfigAxes.reconcileHarnessSwitch(draft.config, to: k)
            modelFilter = ""
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(type.displayName).font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(BrandColors.whiteSwiftUI)
                    Spacer(minLength: 0)
                }
                Text(providerSubline(k))
                    .font(.system(size: 9))
                    .foregroundStyle(isSel ? BrandColors.goldSwiftUI.opacity(0.75) : BrandColors.dimSwiftUI)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(isSel ? EditorTheme.goldGhost : BrandColors.surface2SwiftUI))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(isSel ? BrandColors.goldSwiftUI : BrandColors.ruleSwiftUI, lineWidth: isSel ? 1.2 : 1))
            .overlay(alignment: .topTrailing) {
                if !isInstalled {
                    Text(String(localized: "agentConfigEditor.notInstalled", defaultValue: "NOT INSTALLED"))
                        .font(.system(size: 8)).tracking(0.5).foregroundStyle(BrandColors.dimSwiftUI)
                        .padding(.top, 7).padding(.trailing, 8)
                }
            }
            .opacity(isInstalled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func providerSubline(_ k: String) -> String {
        switch AgentConfigAxes.providerClass(forHarness: k) {
        case .router:
            return String(localized: "agentConfigEditor.provider.router",
                          defaultValue: "OpenRouter · provider by model prefix")
        case .fixed(let label):
            return label
        case .custom:
            return String(localized: "agentConfigEditor.provider.custom", defaultValue: "operator-defined")
        }
    }

    // MARK: Model

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(String(localized: "agentConfigEditor.model", defaultValue: "Model"),
                       trailing: overrideChip(draft.config.model != nil))
            modelControl
        }
    }

    @ViewBuilder private var modelControl: some View {
        switch AgentConfigAxes.modelAxis(forHarness: harness) {
        case .families(let families):
            familiesPanel(families)
        case .router:
            routerPanel
        case .freeform(let providerLabel):
            freeformModel(providerLabel)
        case .none:
            axisOff(String(localized: "agentConfigEditor.model.none",
                           defaultValue: "no model flag — this harness launches whatever its own config selects"))
        }
    }

    private func familiesPanel(_ families: [ClaudeModelFamily]) -> some View {
        let base = AgentConfigAxes.inheritedModelBase(forHarness: harness,
                                                      from: DefaultAgentConfigStore.shared.current) ?? "opus"
        return VStack(alignment: .leading, spacing: 5) {
            VStack(spacing: 0) {
                modelRow(value: nil,
                         label: String(localized: "agentConfigEditor.model.inherit", defaultValue: "Inherit"),
                         note: String(format: String(localized: "agentConfigEditor.model.inheritNote",
                                                      defaultValue: "harness Settings → %@"), base))
                ForEach(families) { family in
                    modelRow(value: family.rawValue, label: family.displayName, note: nil)
                }
            }
            .background(BrandColors.surface2SwiftUI)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(BrandColors.ruleSwiftUI, lineWidth: 1))
            Text(String(format: String(localized: "agentConfigEditor.model.familyHint",
                                        defaultValue: "family alias · claude --model %@ resolves to the latest release; no c11 change on new model drops"),
                        draft.config.model ?? "opus"))
                .font(.system(size: 9.5)).foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
        }
    }

    private var routerPanel: some View {
        VStack(spacing: 0) {
            TextField(String(localized: "agentConfigEditor.model.filter",
                             defaultValue: "filter models… (provider rides the prefix)"),
                      text: $modelFilter)
                .textFieldStyle(.plain).font(.system(size: 11.5))
                .foregroundStyle(BrandColors.whiteSwiftUI)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(BrandColors.ruleSwiftUI), alignment: .bottom)
            ScrollView {
                VStack(spacing: 0) {
                    if modelFilter.isEmpty {
                        modelRow(value: nil,
                                 label: String(localized: "agentConfigEditor.model.inherit", defaultValue: "Inherit"),
                                 note: String(localized: "agentConfigEditor.model.inheritSettings",
                                              defaultValue: "harness Settings"))
                    }
                    ForEach(AgentConfigAxes.routerModelCatalog, id: \.provider) { group in
                        let visible = group.models.filter {
                            modelFilter.isEmpty || $0.lowercased().contains(modelFilter.lowercased())
                        }
                        if !visible.isEmpty {
                            HStack {
                                Text("\(group.provider)/").font(.system(size: 9, weight: .medium))
                                    .tracking(1.3).textCase(.uppercase).foregroundStyle(BrandColors.dimSwiftUI)
                                Spacer()
                                Text(String(localized: "agentConfigEditor.model.providerTag", defaultValue: "provider"))
                                    .font(.system(size: 9)).foregroundStyle(BrandColors.dimSwiftUI)
                            }
                            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
                            .background(BrandColors.surfaceSwiftUI.opacity(0.5))
                            ForEach(visible, id: \.self) { model in
                                let name = model.contains("/") ? String(model.split(separator: "/")[1]) : model
                                modelRow(value: model, label: name, note: nil)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 218)
        }
        .background(BrandColors.surface2SwiftUI)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(BrandColors.ruleSwiftUI, lineWidth: 1))
    }

    private func modelRow(value: String?, label: String, note: String?) -> some View {
        let isSel = draft.config.model == value
        return Button {
            draft.config.model = value
        } label: {
            HStack(spacing: 10) {
                Text(isSel ? "✓" : "").font(.system(size: 10)).foregroundStyle(BrandColors.goldSwiftUI).frame(width: 14)
                Text(label).font(.system(size: 12))
                    .foregroundStyle(isSel ? BrandColors.goldSwiftUI : BrandColors.whiteSwiftUI)
                if let note {
                    Text(note).font(.system(size: 9.5)).foregroundStyle(BrandColors.dimSwiftUI)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isSel ? EditorTheme.goldFaint : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func freeformModel(_ providerLabel: String) -> some View {
        let suggestions = AgentConfigAxes.freeformSuggestions(forHarness: harness)
        let modelBinding = Binding<String>(
            get: { draft.config.model ?? "" },
            set: { draft.config.model = $0.isEmpty ? nil : $0 }
        )
        return VStack(alignment: .leading, spacing: 7) {
            TextField(String(format: String(localized: "agentConfigEditor.model.freeformPlaceholder",
                                            defaultValue: "inherit — %@ default"),
                             AgentRegistry.shared.manifest(forKind: harness)?.displayName ?? harness),
                      text: modelBinding)
                .textFieldStyle(.plain).font(.system(size: 12))
                .foregroundStyle(BrandColors.whiteSwiftUI)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(textFieldFill)
            if !suggestions.isEmpty {
                FlowChips(items: suggestions, selected: draft.config.model) { model in
                    draft.config.model = model
                }
            }
        }
    }

    // MARK: Effort

    private var effortField: some View {
        let chips = AgentConfigAxes.effortChipValues(forHarness: harness)
        let hasAxis = !(AgentConfigAxes.effortAxis(forHarness: harness) == .none)
        return VStack(alignment: .leading, spacing: 6) {
            fieldLabel(String(localized: "agentConfigEditor.effort", defaultValue: "Effort"),
                       trailing: hasAxis ? overrideChip(draft.config.effort != nil) : nil)
            if chips.isEmpty {
                axisOff(String(format: String(localized: "agentConfigEditor.effort.none",
                                              defaultValue: "no effort axis on %@"),
                               AgentRegistry.shared.manifest(forKind: harness)?.displayName ?? harness))
            } else {
                effortChips(chips)
                effortHint
            }
        }
    }

    private func effortChips(_ chips: [String]) -> some View {
        FlowChipsRaw {
            chip(label: String(localized: "agentConfigEditor.effort.inherit", defaultValue: "inherit"),
                 selected: draft.config.effort == nil) { draft.config.effort = nil }
            ForEach(chips, id: \.self) { value in
                chip(label: value, selected: draft.config.effort == value) { draft.config.effort = value }
            }
        }
    }

    @ViewBuilder private var effortHint: some View {
        let hint: String? = {
            switch harness {
            case "codex":
                return String(localized: "agentConfigEditor.effort.codexHint",
                              defaultValue: "rides -c model_reasoning_effort=… — codex enforces values")
            case "pi", "omp":
                return String(localized: "agentConfigEditor.effort.thinkingHint", defaultValue: "rides --thinking")
            default: return nil
            }
        }()
        if let hint {
            Text(hint).font(.system(size: 9.5)).foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
        }
    }

    // MARK: System prompt

    private var systemPromptField: some View {
        let supported = AgentConfigAxes.systemPromptAxis(forHarness: harness) != .none
        let mode = draft.config.systemPrompt?.mode ?? .inherit
        return VStack(alignment: .leading, spacing: 6) {
            fieldLabel(String(localized: "agentConfigEditor.systemPrompt", defaultValue: "System prompt"),
                       trailing: supported ? overrideChip(mode != .inherit) : nil)
            if supported {
                systemPromptControl(mode: mode)
            } else {
                axisOff(String(format: String(localized: "agentConfigEditor.systemPrompt.none",
                                              defaultValue: "no system-prompt flag on %@ — control disabled (same gating as effort)"),
                               AgentRegistry.shared.manifest(forKind: harness)?.displayName ?? harness))
            }
        }
    }

    @ViewBuilder private func systemPromptControl(mode: SystemPromptSetting.Mode) -> some View {
        let textBinding = Binding<String>(
            get: { draft.config.systemPrompt?.text ?? "" },
            set: { draft.config.systemPrompt = SystemPromptSetting(mode: mode, text: $0) }
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(SystemPromptSetting.Mode.allCases, id: \.self) { m in
                    Button {
                        let text = draft.config.systemPrompt?.text ?? ""
                        draft.config.systemPrompt = SystemPromptSetting(mode: m, text: text)
                    } label: {
                        Text(Self.systemPromptModeLabel(m)).font(.system(size: 11))
                            .foregroundStyle(mode == m ? BrandColors.goldSwiftUI : BrandColors.whiteSwiftUI.opacity(0.65))
                            .padding(.horizontal, 13).padding(.vertical, 4)
                            .background(mode == m ? EditorTheme.goldGhost : BrandColors.surface2SwiftUI)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(Rectangle().frame(width: 1).foregroundStyle(BrandColors.ruleSwiftUI),
                             alignment: .trailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(BrandColors.ruleSwiftUI, lineWidth: 1))

            if mode != .inherit {
                TextEditor(text: textBinding)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(BrandColors.whiteSwiftUI)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 54, maxHeight: 90)
                    .padding(6)
                    .background(textFieldFill)
            }
            if mode == .replace, (draft.config.systemPrompt?.text ?? "").isEmpty {
                Text(String(localized: "agentConfigEditor.systemPrompt.blank",
                            defaultValue: "◈ blank slate — launches with --system-prompt '' (the Gregorovich launch)"))
                    .font(.system(size: 10)).foregroundStyle(BrandColors.goldSwiftUI)
            }
        }
    }

    // MARK: Advanced (full recipe: command · initial prompt · env)

    private var advancedField: some View {
        let envBinding = Binding<String>(
            get: { EnvText.toText(draft.config.env) },
            set: { draft.config.env = EnvText.toDict($0) }
        )
        let commandBinding = optionalBinding(\.command)
        let promptBinding = optionalBinding(\.initialPrompt)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { advancedOpen.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Text("▸").font(.system(size: 8)).rotationEffect(.degrees(advancedOpen ? 90 : 0))
                    Text(String(localized: "agentConfigEditor.advanced",
                                defaultValue: "advanced — command · initial prompt · env"))
                        .font(.system(size: 11))
                    Text(String(localized: "agentConfigEditor.advanced.allInherit", defaultValue: "all inherit"))
                        .font(.system(size: 9, weight: .light)).foregroundStyle(Color(white: 0.29))
                    Spacer()
                }
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if advancedOpen {
                advancedInput(String(localized: "agentConfigEditor.command", defaultValue: "Command"),
                              placeholder: AgentRegistry.shared.manifest(forKind: harness)?.factoryCommand ?? "",
                              binding: commandBinding, isOverride: draft.config.command != nil)
                advancedInput(String(localized: "agentConfigEditor.initialPrompt", defaultValue: "Initial prompt"),
                              placeholder: String(localized: "agentConfigEditor.none", defaultValue: "(none)"),
                              binding: promptBinding, isOverride: draft.config.initialPrompt != nil)
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(String(localized: "agentConfigEditor.env", defaultValue: "Env overrides"),
                               trailing: overrideChip(draft.config.env?.isEmpty == false))
                    TextEditor(text: envBinding)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(BrandColors.whiteSwiftUI)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 44, maxHeight: 90).padding(6).background(textFieldFill)
                    Text(String(localized: "agentConfigEditor.env.hint",
                                defaultValue: "KEY=value — one per line, merged over harness env"))
                        .font(.system(size: 9.5)).foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
                }
            }
        }
    }

    private func advancedInput(_ label: String, placeholder: String, binding: Binding<String>, isOverride: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label, trailing: overrideChip(isOverride))
            TextField(placeholder, text: binding)
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(BrandColors.whiteSwiftUI)
                .padding(.horizontal, 10).padding(.vertical, 7).background(textFieldFill)
        }
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<AgentLaunchConfig, String?>) -> Binding<String> {
        Binding<String>(
            get: { draft.config[keyPath: keyPath] ?? "" },
            set: { draft.config[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: Shared bits

    /// Localized label for a system-prompt mode; `rawValue` stays logic-only.
    static func systemPromptModeLabel(_ mode: SystemPromptSetting.Mode) -> String {
        switch mode {
        case .inherit: return String(localized: "agentConfigEditor.sysMode.inherit", defaultValue: "inherit")
        case .append:  return String(localized: "agentConfigEditor.sysMode.append", defaultValue: "append")
        case .replace: return String(localized: "agentConfigEditor.sysMode.replace", defaultValue: "replace")
        }
    }

    private func axisOff(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(Color(white: 0.29)).padding(.vertical, 6)
    }

    private func chip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11))
                .foregroundStyle(selected ? BrandColors.goldSwiftUI : BrandColors.whiteSwiftUI.opacity(0.75))
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? EditorTheme.goldGhost : BrandColors.surface2SwiftUI))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? BrandColors.goldSwiftUI : BrandColors.ruleSwiftUI, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Env text <-> dict

enum EnvText {
    static func toText(_ env: [String: String]?) -> String {
        guard let env, !env.isEmpty else { return "" }
        return env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
    }

    static func toDict(_ text: String) -> [String: String]? {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = String(value) }
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Chip flow layouts

/// A simple wrapping row of selectable suggestion chips.
private struct FlowChips: View {
    let items: [String]
    let selected: String?
    let onSelect: (String) -> Void

    var body: some View {
        FlowChipsRaw {
            ForEach(items, id: \.self) { item in
                Button { onSelect(item) } label: {
                    Text(item).font(.system(size: 11))
                        .foregroundStyle(selected == item ? BrandColors.goldSwiftUI : BrandColors.whiteSwiftUI.opacity(0.75))
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected == item ? BrandColors.goldSwiftUI.opacity(0.10) : BrandColors.surface2SwiftUI))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected == item ? BrandColors.goldSwiftUI : BrandColors.ruleSwiftUI, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A single horizontal row of chip content. Today's chip counts (≤7 effort
/// tiers, ≤3 suggestions) fit the editor's width inside the 860-pt sheet, so no
/// wrapping is needed; revisit if a harness ever declares many more.
private struct FlowChipsRaw<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 6) { content }
    }
}

// MARK: - Launch stats view (design §5.5)

/// The launch-stats view rendered inside the sheet: window chips (today/30d/all),
/// gold leader bars, and the agent-launches.jsonl provenance line. Reads the
/// C11-178 aggregate through `AgentLaunchStatsStore.shared`.
struct LaunchStatsView: View {
    @State private var window: StatsWindow = .all
    @State private var bars: [StatsBarRow] = []
    @State private var total = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    windowChip(.today, String(localized: "agentConfigEditor.stats.today", defaultValue: "today"))
                    windowChip(.days(30), String(localized: "agentConfigEditor.stats.30d", defaultValue: "30d"))
                    windowChip(.all, String(localized: "agentConfigEditor.stats.all", defaultValue: "all time"))
                    Spacer()
                    Text(String(format: String(localized: "agentConfigEditor.stats.query",
                                               defaultValue: "by model · c11 config stats --window %@"), windowFlag))
                        .font(.system(size: 10)).foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.35))
                }
                .padding(.top, 12).padding(.bottom, 16)

                if bars.isEmpty {
                    Text(String(localized: "agentConfigEditor.stats.empty",
                                defaultValue: "no launches recorded yet — launch an agent and it lands here"))
                        .font(.system(size: 11)).foregroundStyle(BrandColors.dimSwiftUI).padding(.vertical, 20)
                } else {
                    ForEach(bars, id: \.label) { row in barRow(row) }
                }

                Text(String(format: String(localized: "agentConfigEditor.stats.provenance",
                                           defaultValue: "%d launches · %@ · source: agent-launches.jsonl — every path (A button, CLI, socket, blueprint, fader) records"),
                            total, windowLabel))
                    .font(.system(size: 10.5)).foregroundStyle(BrandColors.dimSwiftUI).padding(.top, 14)
            }
            .padding(.horizontal, 22).padding(.bottom, 18)
        }
        .task(id: windowFlag) { await reload() }
    }

    private func barRow(_ row: StatsBarRow) -> some View {
        HStack(spacing: 11) {
            Text(row.label).font(.system(size: 11.5)).foregroundStyle(BrandColors.whiteSwiftUI)
                .frame(width: 92, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(BrandColors.surface2SwiftUI)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(row.isLeader
                              ? LinearGradient(colors: [BrandColors.goldSwiftUI.opacity(0.55), BrandColors.goldSwiftUI],
                                               startPoint: .leading, endPoint: .trailing)
                              : LinearGradient(colors: [BrandColors.surface3SwiftUI, BrandColors.surface3SwiftUI],
                                               startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * row.widthOfMax))
                }
            }
            .frame(height: 14)
            Text("\(Int((row.shareOfTotal * 100).rounded()))% (\(row.count))")
                .font(.system(size: 10.5)).foregroundStyle(BrandColors.dimSwiftUI)
                .frame(width: 110, alignment: .leading)
        }
        .padding(.bottom, 9)
    }

    private func windowChip(_ w: StatsWindow, _ label: String) -> some View {
        Button { window = w } label: {
            Text(label).font(.system(size: 11))
                .foregroundStyle(window == w ? BrandColors.goldSwiftUI : BrandColors.whiteSwiftUI.opacity(0.75))
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(window == w ? BrandColors.goldSwiftUI.opacity(0.10) : BrandColors.surface2SwiftUI))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(window == w ? BrandColors.goldSwiftUI : BrandColors.ruleSwiftUI, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var windowFlag: String {
        switch window { case .today: return "today"; case .days: return "30d"; case .all: return "all" }
    }
    private var windowLabel: String {
        switch window {
        case .today: return String(localized: "agentConfigEditor.stats.label.today", defaultValue: "today")
        case .days: return String(localized: "agentConfigEditor.stats.label.30d", defaultValue: "last 30d")
        case .all: return String(localized: "agentConfigEditor.stats.label.all", defaultValue: "all time")
        }
    }

    private func reload() async {
        let w = window
        let result: LaunchStatsResult? = await Task.detached(priority: .userInitiated) {
            AgentLaunchStatsStore.shared?.stats(window: w, by: .model)
        }.value
        guard let result else { bars = []; total = 0; return }
        bars = LaunchStatsBars.statsBars(from: result)
        total = result.count
    }
}

