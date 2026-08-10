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

    private static let focusKindKey = "focusKind"   // "config" | "new"
    private static let focusIdKey = "focusId"       // config id for .config
    private static let originKey = "origin"
    private static let returnToPopoverKey = "returnToPopover"

    static func postOpen(focus: AgentConfigEditorFocus, origin: AgentConfigEditorOrigin) {
        var info: [String: Any] = [originKey: origin.rawValue]
        switch focus {
        case .config(let id): info[focusKindKey] = "config"; info[focusIdKey] = id
        case .new:            info[focusKindKey] = "new"
        }
        NotificationCenter.default.post(name: openName, object: nil, userInfo: info)
    }

    static func focus(from note: Notification) -> AgentConfigEditorFocus {
        switch note.userInfo?[focusKindKey] as? String {
        case "config":
            if let id = note.userInfo?[focusIdKey] as? String { return .config(id) }
            return .new
        default: return .new
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
    /// to call repeatedly. Snapshots the operator's configured per-harness
    /// commands on the main actor so the probe reflects a rebound binary, not
    /// just the factory command.
    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        let base = DefaultAgentConfigStore.shared.current
        let commands = Dictionary(uniqueKeysWithValues:
            AgentType.allCases.map { ($0.rawValue, base.config(for: $0).command) })
        Task.detached(priority: .utility) {
            let dirs = Self.captureLoginShellPath()
            let verdicts = Self.computeVerdicts(pathDirs: dirs, configuredCommands: commands)
            await MainActor.run { self.verdicts = verdicts }
        }
    }

    /// Whether the harness's binary resolves on the captured PATH. Returns `true`
    /// while the PATH is still resolving or on any failure (degrade-never-block).
    /// A pure dictionary read — no filesystem stat on the render path.
    func isInstalled(harness: String) -> Bool {
        verdicts[harness] ?? true
    }

    /// Stat each harness's binary against the captured PATH once, off-main. Uses
    /// the operator's configured command where set, falling back to the factory
    /// command. An empty/unresolved PATH yields `[:]` so every harness reads as
    /// installed.
    private nonisolated static func computeVerdicts(pathDirs: [String]?, configuredCommands: [String: String]) -> [String: Bool] {
        guard let dirs = pathDirs, !dirs.isEmpty else { return [:] }
        let fm = FileManager.default
        var out: [String: Bool] = [:]
        for type in AgentType.allCases {
            let configured = configuredCommands[type.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
            let command = configured.isEmpty
                ? (AgentRegistry.shared.manifest(forKind: type.rawValue)?.factoryCommand ?? "")
                : configured
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

    /// The configs that may hold the pinned default. An unlaunchable recipe is
    /// refused by the store (`StoreError.configUnlaunchable`, C11-203 A2), so
    /// offering it in the Default menu would only produce a click that quietly
    /// does nothing — the defect class this ticket exists to kill.
    var pinnableConfigs: [SavedAgentConfig] {
        configs.filter { !$0.config.isProvablyUnlaunchable }
    }

    /// Save the draft (add when `sourceId == nil`, else update in place). Returns
    /// the stored config (with its resolved id), or nil on a store error or a
    /// recipe the editor refuses to write (C11-203 C4). Callers show the
    /// specific refusal via `AgentConfigAxes.saveRefusal`; this guard is the
    /// backstop so no path can write an unlaunchable recipe over a working one.
    @discardableResult
    func save(_ draft: EditorDraft) -> SavedAgentConfig? {
        let name = draft.resolvedName
        let config = draft.normalizedConfig
        guard AgentConfigAxes.saveRefusal(for: config) == nil else { return nil }
        do {
            // Update path: only when the id still exists in the on-disk file.
            if let id = draft.sourceId {
                var file = store.current
                if let i = file.configs.firstIndex(where: { $0.id == id }) {
                    let updated = SavedAgentConfig(id: id, name: name, order: file.configs[i].order, config: config)
                    file.configs[i] = updated
                    try store.write(file)
                    reload()
                    return updated
                }
                // The id vanished (deleted out from under us): fall through to add
                // rather than silently reporting a save that never happened.
            }
            let stored = try store.add(SavedAgentConfig(id: "", name: name, order: 0, config: config))
            reload()
            return stored
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

    /// Pin a config as the default. Returns an operator-facing sentence when the
    /// store refuses, `nil` on success. A bare `try?` here would swallow
    /// `StoreError.configUnlaunchable` and leave the ● quietly failing to move
    /// — a silent no-op in exactly the class of bug C11-203 exists to kill.
    @discardableResult
    func setDefault(id: String) -> String? {
        do {
            try store.setDefault(configId: id)
        } catch let error as AgentConfigLibraryStore.StoreError {
            switch error {
            case .configUnlaunchable:
                return String(
                    localized: "agentConfigEditor.default.unlaunchable",
                    defaultValue: "That config can't launch as written, so it can't be the default — give it a command first."
                )
            default:
                return defaultPinFailedMessage
            }
        } catch {
            return defaultPinFailedMessage
        }
        reload()
        return nil
    }

    private var defaultPinFailedMessage: String {
        String(
            localized: "agentConfigEditor.default.failed",
            defaultValue: "Couldn't set the default — please try again."
        )
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

    /// The config as it should be persisted — an explicit `.inherit` system
    /// prompt (transient editor state) collapses to `nil` (true inherit).
    var normalizedConfig: AgentLaunchConfig {
        AgentConfigAxes.normalizedForPersistence(config)
    }

    static func new() -> EditorDraft {
        // systemPrompt nil = inherit; the editor renders `?? .inherit` for display.
        EditorDraft(sourceId: nil, name: "", config: AgentLaunchConfig(harness: "claude-code"))
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

/// Tier 2 of the model picker (design §5.4): the Saved Configs editor,
/// reproduced from the binding prototype. Presented as a `.sheet` from the
/// Settings section.
struct AgentConfigEditorSheet: View {
    @ObservedObject var library: AgentConfigLibraryViewModel
    let initialFocus: AgentConfigEditorFocus
    /// Called when the operator closes the sheet; `returnToPopover` is true only
    /// on a Back/Esc backout (not after a launch).
    var onClose: (_ returnToPopover: Bool) -> Void

    @StateObject private var installed = AgentInstalledProbe.shared
    @State private var draft: EditorDraft = .new()
    /// The chosen provider axis (C11-203 C1). Editor-only state: the file
    /// schema stores harness/model, so this is derived when a config is
    /// selected and cascaded downward while editing.
    @State private var provider: String?
    @State private var advancedOpen = false
    @State private var modelFilter = ""
    @State private var savedFlashId: String?
    @State private var launchFeedback: String?
    /// Bumped when a background catalog refresh lands, so the provider/model
    /// controls re-read the store. The catalog is not observable and a refresh
    /// is ~5 s of subprocesses: the editor renders from cache immediately and
    /// updates in place rather than blocking on it.
    @State private var catalogVersion = 0

    /// The live model catalog (Part D). Read through the editor's wider
    /// protocol so the pure axis logic in `AgentConfigAxes` can be tested
    /// against a stub that never shells out.
    private var catalog: any EditorModelCatalog { ModelCatalogStore.shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(BrandColors.ruleSwiftUI)
            HStack(spacing: 0) {
                libraryRail
                Divider().overlay(BrandColors.ruleSwiftUI)
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
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
        .frame(width: EditorTheme.sheetWidth)
        .frame(maxHeight: 640)
        .background(BrandColors.surfaceSwiftUI)
        .environment(\.colorScheme, .dark)
        .overlay(hiddenKeyboardCatchers)
        .onAppear {
            installed.startIfNeeded()
            applyFocus(initialFocus)
            refreshCatalogIfStale()
        }
    }

    // Hidden buttons that catch Return (Save) and Escape (Back). Return is
    // bound here only — the visible Save button draws the ⏎ glyph but must not
    // declare a second `.defaultAction` (C11-203 F2).
    private var hiddenKeyboardCatchers: some View {
        ZStack {
            Button("", action: backOut).keyboardShortcut(.cancelAction).hidden()
            Button("", action: saveOnly).keyboardShortcut(.defaultAction).hidden()
        }
        .frame(width: 0, height: 0)
    }

    /// Kick a background re-enumeration of the harness CLIs when the cached
    /// catalog is old. Completion lands on the main queue and only bumps a
    /// counter; nothing here blocks the sheet appearing.
    private func refreshCatalogIfStale() {
        ModelCatalogStore.shared.refreshIfStale { catalogVersion &+= 1 }
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
                Text(String(localized: "agentConfigEditor.title", defaultValue: "Agent Configurations"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(BrandColors.whiteSwiftUI)
                Text(String(localized: "agentConfigEditor.subtitle",
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
                // The unsaved draft rides outside the movable ForEach so drag
                // indices keep matching the stored configs one-for-one.
                if isEditingNewConfig {
                    provisionalRow
                        .listRowBackground(EditorTheme.goldFaint)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
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

    /// Whether the draft has never been written, i.e. the rail must show the
    /// provisional row (C11-203 F1). `store.add` appends, so the row sits where
    /// the config will actually land.
    private var isEditingNewConfig: Bool { draft.sourceId == nil }

    /// The unsaved draft, shown in the left list so "New config" produces
    /// visible, selected feedback instead of silently swapping the right pane.
    /// It exists only in this view: abandoning the sheet leaves no junk row.
    private var provisionalRow: some View {
        HStack(spacing: 8) {
            Text("＋").font(.system(size: 10)).foregroundStyle(BrandColors.goldSwiftUI.opacity(0.7))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(provisionalName).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(BrandColors.whiteSwiftUI)
                    Text(String(localized: "agentConfigEditor.unsaved", defaultValue: "unsaved"))
                        .font(.system(size: 8.5, weight: .medium)).textCase(.uppercase).tracking(0.8)
                        .foregroundStyle(BrandColors.goldSwiftUI)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(BrandColors.goldSwiftUI.opacity(0.55), lineWidth: 1))
                }
                Text(sublineText(draft.config))
                    .font(.system(size: 9.5)).foregroundStyle(BrandColors.dimSwiftUI)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(BrandColors.goldSwiftUI.opacity(0.45))
            .padding(.horizontal, 4))
    }

    private var provisionalName: String {
        let typed = draft.name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty
            ? String(localized: "agentConfigEditor.newItem", defaultValue: "New item")
            : typed
    }

    private func rowBackground(_ config: SavedAgentConfig) -> Color {
        if draft.sourceId == config.id { return EditorTheme.goldFaint }
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
            provider: $provider,
            advancedOpen: $advancedOpen,
            modelFilter: $modelFilter,
            installed: installed,
            catalog: catalog
        )
        // A landed refresh changes what the catalog answers; the id forces the
        // provider/model controls to re-read it.
        .id(catalogVersion)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(String(localized: "agentConfigEditor.default", defaultValue: "Default"))
                .font(.system(size: 9, weight: .medium)).textCase(.uppercase).tracking(1.2)
                .foregroundStyle(BrandColors.dimSwiftUI)
            Menu {
                // Only launchable configs are offered: the store refuses to pin
                // anything else, and a menu entry that quietly fails is the
                // silent no-op C11-203 is about (A2 / defect 2).
                ForEach(library.pinnableConfigs, id: \.id) { config in
                    Button(config.name) { pinDefault(config.id) }
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

            Spacer()

            // Save is the primary act (C11-203 F2): most edits end here, and
            // launching is the occasional follow-on, not the default gesture.
            Button(String(localized: "agentConfigEditor.saveLaunch", defaultValue: "Save & Launch"),
                   action: saveAndLaunch)
                .buttonStyle(.bordered)
            Button(action: saveOnly) {
                HStack(spacing: 8) {
                    Text(String(localized: "agentConfigEditor.save", defaultValue: "Save"))
                    Text("\u{23CE}").opacity(0.55).font(.system(size: 11))
                }
            }
            .buttonStyle(GoldCTAButtonStyle())
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(BrandColors.surfaceSwiftUI.opacity(0.6))
    }

    // MARK: Actions

    private func applyFocus(_ focus: AgentConfigEditorFocus) {
        switch focus {
        case .config(let id):
            if let match = library.configs.first(where: { $0.id == id }) { selectConfig(match) }
            else { newConfig() }
        case .new:
            newConfig()
        }
    }

    private func selectConfig(_ config: SavedAgentConfig) {
        draft = .from(config)
        provider = AgentConfigAxes.derivedProvider(for: config.config, catalog: catalog)
        advancedOpen = false
        modelFilter = ""
        launchFeedback = nil
    }

    private func newConfig() {
        draft = .new()
        provider = AgentConfigAxes.derivedProvider(for: draft.config, catalog: catalog)
        advancedOpen = false
        modelFilter = ""
        launchFeedback = nil
    }

    /// Save, refusing a recipe that could never launch (C11-203 C4). The
    /// refusal is stated in the same feedback line the launch declines use, so
    /// the operator always learns why nothing happened.
    @discardableResult
    private func persistDraft() -> SavedAgentConfig? {
        launchFeedback = nil
        if let refusal = AgentConfigAxes.saveRefusal(for: draft.normalizedConfig) {
            launchFeedback = refusal.message
            return nil
        }
        guard let saved = library.save(draft) else {
            launchFeedback = saveFailedMessage
            return nil
        }
        draft.sourceId = saved.id
        return saved
    }

    private func saveOnly() {
        guard let saved = persistDraft() else { return }
        flashSaved(saved.id)
    }

    private func saveAndLaunch() {
        guard let saved = persistDraft() else { return }
        // Never silently no-op (design MINOR-5): keep the sheet open + explain
        // when there is nothing to launch into or the recipe can't launch.
        switch AppDelegate.shared?.launchSavedAgentConfig(saved) ?? .noWorkspace {
        case .launched:
            onClose(false) // launched — do not return to the popover
        case .noWorkspace:
            flashSaved(saved.id)
            launchFeedback = String(localized: "agentConfigEditor.launch.noWorkspace",
                                    defaultValue: "Saved. No workspace open to launch into — open one, then launch.")
        case .cannotLaunch(let reason):
            // The launch path names its own decline (C11-203 A1), so the sheet
            // states the actual reason instead of a generic sentence.
            flashSaved(saved.id)
            launchFeedback = String(
                format: String(localized: "agentConfigEditor.launch.declined",
                               defaultValue: "Saved, but it didn't launch. %@"),
                reason.message
            )
        }
    }

    private func pinDefault(_ id: String) {
        launchFeedback = library.setDefault(id: id)
    }

    private var saveFailedMessage: String {
        String(localized: "agentConfigEditor.saveFailed", defaultValue: "Couldn't save — please try again.")
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

// MARK: - Recipe editor (provider-first axis order, C11-203 Part C)

/// The right-hand recipe editor: provider → model → effort → harness → system
/// prompt → advanced, each overridable field carrying an inherit/override
/// state chip.
///
/// The order is the operator's framing, not an implementation convenience:
/// pick the brain, pick how hard it thinks, then decide which shell runs it.
/// Harness is the last question and is filtered by what can actually serve the
/// chosen model, so every pair the editor offers is a pair that launches.
struct AgentConfigRecipeEditor: View {
    @Binding var draft: EditorDraft
    @Binding var provider: String?
    @Binding var advancedOpen: Bool
    @Binding var modelFilter: String
    @ObservedObject var installed: AgentInstalledProbe
    let catalog: any EditorModelCatalog

    private var harness: String { draft.config.harness }

    /// The four-axis state the pure cascade operates on.
    private var selection: AgentConfigAxisSelection {
        AgentConfigAxisSelection(provider: provider, config: draft.config)
    }

    private func apply(_ next: AgentConfigAxisSelection) {
        provider = next.provider
        draft.config = next.config
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                nameField
                providerField
                modelField
                effortField
                harnessField
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

    // MARK: Provider (the root axis, C11-203 C1)

    private var providerField: some View {
        let options = AgentConfigAxes.providerOptions(selected: provider, catalog: catalog)
        return VStack(alignment: .leading, spacing: 6) {
            fieldLabel(String(localized: "agentConfigEditor.provider", defaultValue: "Provider"),
                       trailing: AnyView(
                        Text(String(localized: "agentConfigEditor.provider.hint",
                                    defaultValue: "pick the brain — model, effort and harness follow"))
                            .font(.system(size: 9, weight: .light)).foregroundStyle(Color(white: 0.29))))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                providerCard(nil)
                ForEach(options.prominent, id: \.self) { key in providerCard(key) }
                if !options.overflow.isEmpty { overflowProviderCard(options.overflow) }
            }
        }
    }

    private func providerCard(_ key: String?) -> some View {
        let isSel = provider == key
        let count = key.map { catalog.models(forProvider: $0).count } ?? 0
        return Button {
            select(provider: key)
        } label: {
            providerCardBody(
                title: key.map(ModelCatalogProviders.displayName)
                    ?? String(localized: "agentConfigEditor.provider.inherit", defaultValue: "Inherit"),
                subtitle: key == nil
                    ? String(localized: "agentConfigEditor.provider.inheritNote",
                             defaultValue: "harness picks its own")
                    : String(format: String(localized: "agentConfigEditor.provider.modelCount",
                                            defaultValue: "%lld models"), count),
                isSelected: isSel
            )
        }
        .buttonStyle(.plain)
    }

    /// The long tail. Forty of the catalog's providers publish five models or
    /// fewer, so they live behind one menu rather than forty cards.
    private func overflowProviderCard(_ keys: [String]) -> some View {
        Menu {
            ForEach(keys, id: \.self) { key in
                Button(String(format: String(localized: "agentConfigEditor.provider.overflowRow",
                                             defaultValue: "%@ (%lld)"),
                              ModelCatalogProviders.displayName(key),
                              catalog.models(forProvider: key).count)) {
                    select(provider: key)
                }
            }
        } label: {
            providerCardBody(
                title: String(localized: "agentConfigEditor.provider.more", defaultValue: "More…"),
                subtitle: String(format: String(localized: "agentConfigEditor.provider.moreCount",
                                                defaultValue: "%lld more"), keys.count),
                isSelected: false
            )
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
    }

    private func providerCardBody(title: String, subtitle: String, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(BrandColors.whiteSwiftUI).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(isSelected ? BrandColors.goldSwiftUI.opacity(0.75) : BrandColors.dimSwiftUI)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? EditorTheme.goldGhost : BrandColors.surface2SwiftUI))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isSelected ? BrandColors.goldSwiftUI : BrandColors.ruleSwiftUI,
                                                          lineWidth: isSelected ? 1.2 : 1))
        .contentShape(Rectangle())
    }

    private func select(provider key: String?) {
        apply(AgentConfigAxes.selectingProvider(key, in: selection, catalog: catalog))
        modelFilter = ""
    }

    // MARK: Model

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(String(localized: "agentConfigEditor.model", defaultValue: "Model"),
                       trailing: overrideChip(draft.config.model != nil))
            if AgentConfigAxes.acceptsModel(forHarness: harness) {
                modelPanel
            } else {
                axisOff(String(localized: "agentConfigEditor.model.none",
                               defaultValue: "no model flag — this harness launches whatever its own config selects"))
            }
        }
    }

    private var modelPanel: some View {
        let models = AgentConfigAxes.modelOptions(provider: provider, query: modelFilter, catalog: catalog)
        let current = AgentConfigAxes.resolvedModel(for: selection, catalog: catalog)
        return VStack(spacing: 0) {
            TextField(modelSearchPlaceholder, text: $modelFilter)
                .textFieldStyle(.plain).font(.system(size: 11.5))
                .foregroundStyle(BrandColors.whiteSwiftUI)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(BrandColors.ruleSwiftUI), alignment: .bottom)
            ScrollView {
                VStack(spacing: 0) {
                    if modelFilter.isEmpty { inheritModelRow }
                    if models.isEmpty {
                        axisOff(modelFilter.isEmpty
                                ? String(localized: "agentConfigEditor.model.pickProvider",
                                         defaultValue: "pick a provider above, or search every catalog from here")
                                : String(localized: "agentConfigEditor.model.noMatches",
                                         defaultValue: "no models match"))
                            .padding(.horizontal, 12)
                    }
                    ForEach(models, id: \.rowIdentity) { model in
                        catalogModelRow(model, isSelected: current == model)
                    }
                }
            }
            .frame(maxHeight: 218)
        }
        .background(BrandColors.surface2SwiftUI)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(BrandColors.ruleSwiftUI, lineWidth: 1))
    }

    private var modelSearchPlaceholder: String {
        if let provider {
            return String(format: String(localized: "agentConfigEditor.model.searchProvider",
                                         defaultValue: "search %lld %@ models…"),
                          catalog.models(forProvider: provider).count,
                          ModelCatalogProviders.displayName(provider))
        }
        return String(localized: "agentConfigEditor.model.searchAll",
                      defaultValue: "search every provider's models…")
    }

    private var inheritModelRow: some View {
        let base = AgentConfigAxes.inheritedModelBase(forHarness: harness,
                                                      from: DefaultAgentConfigStore.shared.current)
        let note = base.map {
            String(format: String(localized: "agentConfigEditor.model.inheritNote",
                                  defaultValue: "harness Settings → %@"), $0)
        } ?? String(localized: "agentConfigEditor.model.inheritSettings", defaultValue: "harness Settings")
        return modelRowChrome(
            isSelected: draft.config.model == nil,
            isEnabled: true,
            label: String(localized: "agentConfigEditor.model.inherit", defaultValue: "Inherit"),
            note: note,
            trailing: nil
        ) {
            apply(AgentConfigAxes.selectingModel(nil, in: selection, catalog: catalog))
        }
    }

    private func catalogModelRow(_ model: CatalogModel, isSelected: Bool) -> some View {
        let name = model.displayName.isEmpty ? model.id : model.displayName
        let note = name == model.id ? nil : model.id
        // The trailing slot is the row's one variable affordance: coming-soon,
        // the publisher's deprecation pointer, or the context window.
        let trailing: String? = {
            if model.isComingSoon {
                return String(localized: "agentConfigEditor.model.comingSoon", defaultValue: "coming soon")
            }
            if let successor = catalog.publishedUpgradeTarget(for: model) {
                return String(format: String(localized: "agentConfigEditor.model.upgradeTo",
                                             defaultValue: "→ %@"), successor)
            }
            return model.contextWindow.map(Self.contextLabel)
        }()
        return modelRowChrome(
            isSelected: isSelected,
            isEnabled: !model.isComingSoon,
            label: name,
            note: note,
            trailing: trailing
        ) {
            apply(AgentConfigAxes.selectingModel(model, in: selection, catalog: catalog))
        }
        // The vendor's own deprecation copy beats anything c11 would compose,
        // and it is far too long for the row — so it rides as the tooltip.
        .help(catalog.publishedUpgradeNote(for: model) ?? "")
    }

    /// `1048576` → `1.0M`, `262144` → `262K`. Approximate on purpose: this is a
    /// sub-line hint, not a quota.
    static func contextLabel(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_048_576) }
        if tokens >= 1_000 { return "\(tokens / 1024)K" }
        return "\(tokens)"
    }

    private func modelRowChrome(
        isSelected: Bool,
        isEnabled: Bool,
        label: String,
        note: String?,
        trailing: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(isSelected ? "✓" : "").font(.system(size: 10))
                    .foregroundStyle(BrandColors.goldSwiftUI).frame(width: 14)
                Text(label).font(.system(size: 12))
                    .foregroundStyle(isSelected ? BrandColors.goldSwiftUI : BrandColors.whiteSwiftUI)
                    .lineLimit(1)
                if let note {
                    Text(note).font(.system(size: 9.5)).foregroundStyle(BrandColors.dimSwiftUI)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).font(.system(size: 9)).foregroundStyle(BrandColors.dimSwiftUI)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isSelected ? EditorTheme.goldFaint : Color.clear)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: Effort (Part E1 — hidden outright when the pair has no effort)

    @ViewBuilder private var effortField: some View {
        if let options = AgentConfigAxes.effortOptions(for: selection, catalog: catalog) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(String(localized: "agentConfigEditor.effort", defaultValue: "Effort"),
                           trailing: overrideChip(draft.config.effort != nil))
                effortChips(options)
                effortHint
            }
        }
    }

    private func effortChips(_ chips: [String]) -> some View {
        FlowChipsRaw {
            chip(label: inheritEffortLabel, selected: draft.config.effort == nil) { selectEffort(nil) }
            ForEach(chips, id: \.self) { value in
                chip(label: value, selected: draft.config.effort == value) { selectEffort(value) }
            }
        }
    }

    /// "inherit" says nothing about what will actually run. The publisher's own
    /// default for the pair (codex runs Sol at `low`, Terra at `medium`) is
    /// shown on the chip rather than written into the recipe, so inherit stays
    /// inherit.
    private var inheritEffortLabel: String {
        let plain = String(localized: "agentConfigEditor.effort.inherit", defaultValue: "inherit")
        guard let resolved = AgentConfigAxes.inheritedEffortLabel(
            for: selection,
            from: DefaultAgentConfigStore.shared.current,
            catalog: catalog
        ) else { return plain }
        return String(format: String(localized: "agentConfigEditor.effort.inheritResolved",
                                     defaultValue: "inherit · %@"), resolved)
    }

    private func selectEffort(_ value: String?) {
        apply(AgentConfigAxes.selectingEffort(value, in: selection, catalog: catalog))
    }

    @ViewBuilder private var effortHint: some View {
        let hint: String? = {
            switch harness {
            case "codex":
                return String(localized: "agentConfigEditor.effort.codexHint",
                              defaultValue: "rides -c model_reasoning_effort=… — codex enforces values")
            case "pi", "omp":
                return String(localized: "agentConfigEditor.effort.thinkingHint", defaultValue: "rides --thinking")
            case AgentConfigAxes.kimiHarnessKey:
                return String(format: String(localized: "agentConfigEditor.effort.kimiHint",
                                             defaultValue: "kimi has no effort flag — rides %@ in the launch environment"),
                              AgentConfigAxes.kimiEffortEnvKey)
            default: return nil
            }
        }()
        if let hint {
            Text(hint).font(.system(size: 9.5)).foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
        }
    }

    // MARK: Harness (the last question, Part C2)

    private var harnessField: some View {
        let options = AgentConfigAxes.harnessOptions(for: selection, catalog: catalog)
        return VStack(alignment: .leading, spacing: 6) {
            fieldLabel(String(localized: "agentConfigEditor.harness", defaultValue: "Harness"),
                       trailing: AnyView(
                        Text(String(localized: "agentConfigEditor.harness.hint",
                                    defaultValue: "the last question — which shell runs it"))
                            .font(.system(size: 9, weight: .light)).foregroundStyle(Color(white: 0.29))))
            if options.count == 1, let only = options.first {
                resolvedHarnessRow(only)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                    ForEach(options, id: \.self) { key in
                        harnessCard(key, isDefault: key == options.first)
                    }
                }
            }
        }
    }

    /// Exactly one harness can serve the pair: state it rather than presenting
    /// a one-option choice (Part C2).
    private func resolvedHarnessRow(_ key: String) -> some View {
        HStack(spacing: 8) {
            Text(Self.harnessDisplayName(key)).font(.system(size: 12, weight: .medium))
                .foregroundStyle(BrandColors.goldSwiftUI)
            Text(String(localized: "agentConfigEditor.harness.onlyOne",
                        defaultValue: "the only harness that serves this model"))
                .font(.system(size: 9.5)).foregroundStyle(BrandColors.dimSwiftUI)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(EditorTheme.goldGhost))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(BrandColors.goldSwiftUI, lineWidth: 1.2))
    }

    private func harnessCard(_ key: String, isDefault: Bool) -> some View {
        let isSel = harness == key
        let isInstalled = installed.isInstalled(harness: key)
        return Button {
            apply(AgentConfigAxes.selectingHarness(key, in: selection, catalog: catalog))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(Self.harnessDisplayName(key)).font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(BrandColors.whiteSwiftUI)
                    Spacer(minLength: 0)
                }
                Text(isDefault
                     ? String(localized: "agentConfigEditor.harness.default", defaultValue: "default for this model")
                     : String(localized: "agentConfigEditor.harness.alternate", defaultValue: "also serves it"))
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

    static func harnessDisplayName(_ key: String) -> String {
        AgentType(rawValue: key)?.displayName
            ?? AgentRegistry.shared.manifest(forKind: key)?.displayName
            ?? key
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

// MARK: - Catalog row identity

fileprivate extension CatalogModel {
    /// Stable `ForEach` identity. `id` alone is not unique across a
    /// whole-catalog search: two providers can publish the same bare model id.
    var rowIdentity: String { provider + "/" + id }
}

// MARK: - Chip flow layouts

/// A single horizontal row of chip content. Today's chip counts (≤7 effort
/// tiers) fit the editor's width inside the 860-pt sheet, so no wrapping is
/// needed; revisit if a harness ever declares many more.
private struct FlowChipsRaw<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 6) { content }
    }
}
