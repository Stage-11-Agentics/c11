import SwiftUI
import Combine

/// View-model for the "default agent" Settings section.
@MainActor
final class DefaultAgentSettingsViewModel: ObservableObject {
    @Published var defaultAgent: AgentType
    @Published var editingAgent: AgentType
    @Published var command: String
    @Published var model: String
    @Published var effort: String
    @Published var initialPrompt: String
    @Published var envOverridesText: String

    private let store: DefaultAgentConfigStore
    private var cancellables: Set<AnyCancellable> = []
    private var suppressSave = false

    init(store: DefaultAgentConfigStore = .shared) {
        self.store = store
        let cfg = store.current
        let active = cfg.defaultAgent
        let entry = cfg.config(for: active)
        self.defaultAgent = active
        self.editingAgent = active
        self.command = entry.command
        self.model = entry.model
        self.effort = entry.effort
        self.initialPrompt = entry.initialPrompt
        self.envOverridesText = entry.envOverridesText

        $defaultAgent.dropFirst().sink { [weak self] new in
            guard let self else { return }
            self.store.setDefaultAgent(new)
            self.editingAgent = new
        }.store(in: &cancellables)

        $editingAgent.dropFirst().sink { [weak self] new in
            self?.loadFields(for: new)
        }.store(in: &cancellables)

        $command.dropFirst().sink { [weak self] _ in self?.persistFields() }.store(in: &cancellables)
        $model.dropFirst().sink { [weak self] _ in self?.persistFields() }.store(in: &cancellables)
        $effort.dropFirst().sink { [weak self] _ in self?.persistFields() }.store(in: &cancellables)
        $initialPrompt.dropFirst().sink { [weak self] _ in self?.persistFields() }.store(in: &cancellables)
        $envOverridesText.dropFirst().sink { [weak self] _ in self?.persistFields() }.store(in: &cancellables)
    }

    /// Whether c11 pins a `--model` flag for the agent currently being edited,
    /// gating whether the model picker is shown.
    var editingAgentSupportsModel: Bool {
        DefaultAgentResolver.supportsModelFlag(editingAgent)
    }

    /// Whether c11 pins an `--effort` flag for the agent currently being edited,
    /// gating whether the effort picker is shown.
    var editingAgentSupportsEffort: Bool {
        DefaultAgentResolver.supportsEffortFlag(editingAgent)
    }

    private func loadFields(for agent: AgentType) {
        suppressSave = true
        defer { suppressSave = false }
        let entry = store.current.config(for: agent)
        command = entry.command
        model = entry.model
        effort = entry.effort
        initialPrompt = entry.initialPrompt
        envOverridesText = entry.envOverridesText
    }

    private func persistFields() {
        guard !suppressSave else { return }
        let captured = editingAgent
        let snapshot = AgentConfig(
            command: command,
            initialPrompt: initialPrompt,
            envOverridesText: envOverridesText,
            model: model,
            effort: effort
        )
        store.update(captured) { $0 = snapshot }
    }

    /// Reset all fields for the currently-edited agent to factory defaults.
    func resetEditingAgent() {
        suppressSave = true
        let factory = AgentConfig.factory(for: editingAgent)
        command = factory.command
        model = factory.model
        effort = factory.effort
        initialPrompt = factory.initialPrompt
        envOverridesText = factory.envOverridesText
        suppressSave = false
        store.update(editingAgent) { $0 = factory }
    }
}

/// Identifies a presentation of the agent-config editor sheet.
struct AgentConfigEditorPresentation: Identifiable {
    let id = UUID()
    let focus: AgentConfigEditorFocus
}

struct DefaultAgentSettingsSection: View {
    @StateObject private var vm = DefaultAgentSettingsViewModel()
    @StateObject private var library = AgentConfigLibraryViewModel()
    @State private var showEnvOverrides = false
    @State private var editorPresentation: AgentConfigEditorPresentation?
    @State private var editorOrigin: AgentConfigEditorOrigin = .settings
    @State private var pendingReturnToPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Tier 0 — the saved-config library (C11-182), above the per-harness editor.
            savedConfigsSubsection

            Divider()

            // Tier 1 — which agent the A button launches.
            HStack(spacing: 8) {
                Text(String(localized: "settings.defaultAgent.picker.label",
                            defaultValue: "default agent"))
                    .font(.callout)
                Picker("", selection: $vm.defaultAgent) {
                    ForEach(AgentType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("DefaultAgentPicker")
                Spacer()
            }

            Divider()

            // Tier 2 — per-agent configuration.
            Text(perAgentHeading(for: vm.editingAgent))
                .font(.headline)

            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "settings.defaultAgent.command.label", defaultValue: "command"))
                    .font(.callout)
                TextField("", text: $vm.command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("DefaultAgentCommandField")
                Text(commandHelp(for: vm.editingAgent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if vm.editingAgentSupportsModel {
                modelPicker
            }

            if vm.editingAgentSupportsEffort {
                effortPicker
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "settings.defaultAgent.initialPrompt.label", defaultValue: "initial prompt"))
                    .font(.callout)
                TextEditor(text: $vm.initialPrompt)
                    .frame(minHeight: 38, maxHeight: 90)
                    .font(.system(.body, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .accessibilityIdentifier("DefaultAgentInitialPromptField")
                Text(String(localized: "settings.defaultAgent.initialPrompt.help",
                            defaultValue: "optional. given to the agent immediately after it boots."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Env overrides — DisclosureGroup misbehaves inside the SettingsCard
            // padding, so we build the same affordance from a plain Button so
            // the chevron + label are unambiguously clickable.
            envOverridesDisclosure

            HStack {
                Spacer()
                Button(String(localized: "settings.defaultAgent.reset",
                              defaultValue: "reset agent to defaults")) {
                    vm.resetEditingAgent()
                }
                .controlSize(.small)
            }
        }
        .sheet(item: $editorPresentation, onDismiss: handleEditorDismiss) { presentation in
            AgentConfigEditorSheet(
                library: library,
                initialFocus: presentation.focus,
                onClose: { returnToPopover in
                    pendingReturnToPopover = returnToPopover && editorOrigin == .popover
                    editorPresentation = nil
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentConfigEditorRequest.openName)) { note in
            editorOrigin = AgentConfigEditorRequest.origin(from: note)
            editorPresentation = AgentConfigEditorPresentation(focus: AgentConfigEditorRequest.focus(from: note))
        }
        .onAppear { library.reload() }
    }

    /// Post the close request from the dismiss handler (fires for Back/Esc/launch
    /// and any programmatic dismissal) so the C11-181 popover is never stranded.
    /// When the operator backed out of a popover-origin session, order the
    /// Settings window out so the popover returns as the single visible surface.
    private func handleEditorDismiss() {
        if pendingReturnToPopover {
            SettingsWindowController.shared.window?.orderOut(nil)
        }
        AgentConfigEditorRequest.postClosed(returnToPopover: pendingReturnToPopover)
        pendingReturnToPopover = false
        editorOrigin = .settings
        library.reload()
    }

    // MARK: - Saved Configs subsection (design §5.4)

    private var savedConfigsSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "settings.savedConfigs.heading", defaultValue: "Saved configs"))
                .font(.headline)
            Text(String(localized: "settings.savedConfigs.note",
                        defaultValue: "each config is a full launch recipe layered over its harness's Settings. click one to edit; the A button launches the pinned default."))
                .font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(library.configs, id: \.id) { config in
                    savedConfigRow(config)
                    Divider().opacity(0.4)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))

            HStack(spacing: 12) {
                Text(String(localized: "settings.savedConfigs.default", defaultValue: "Default:"))
                    .font(.callout)
                Menu {
                    ForEach(library.configs, id: \.id) { config in
                        Button(config.name) { library.setDefault(id: config.id) }
                    }
                } label: {
                    Text(library.pinnedConfig?.name
                         ?? String(localized: "settings.savedConfigs.none", defaultValue: "—"))
                }
                .fixedSize()
                Toggle(String(localized: "settings.savedConfigs.followRecent", defaultValue: "follow most recent"),
                       isOn: Binding(
                        get: { library.defaultState.mode == .followRecent },
                        set: { library.setFollowRecent($0) }))
                    .toggleStyle(.checkbox).controlSize(.small)
                Spacer()
            }

            HStack(spacing: 14) {
                Button {
                    openEditor(.new)
                } label: {
                    Label(String(localized: "settings.savedConfigs.new", defaultValue: "New config"),
                          systemImage: "plus")
                }
                Button(String(localized: "settings.savedConfigs.viewAll", defaultValue: "View all models & configs…")) {
                    // Land on the pinned config, else the first — never a blank
                    // new draft (that is what "New config" is for).
                    openEditor(library.pinnedConfig.map { .config($0.id) }
                               ?? library.configs.first.map { .config($0.id) }
                               ?? .new)
                }
                Button(String(localized: "settings.savedConfigs.stats", defaultValue: "Launch stats")) {
                    openEditor(.stats)
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private func savedConfigRow(_ config: SavedAgentConfig) -> some View {
        // Not a Button wrapping a Button (a macOS SwiftUI footgun): the row is a
        // tappable HStack; the trash is the only nested Button.
        HStack(spacing: 8) {
            Text(library.isPinnedDefault(config) ? "●" : "○")
                .foregroundStyle(library.isPinnedDefault(config) ? Color.accentColor : Color.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.name).font(.callout)
                Text(AgentConfigAxes.subline(config.config))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { openEditor(.config(config.id)) }
            Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
            Button {
                library.remove(id: config.id)
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "settings.savedConfigs.delete", defaultValue: "Delete this config"))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func openEditor(_ focus: AgentConfigEditorFocus) {
        editorOrigin = .settings
        editorPresentation = AgentConfigEditorPresentation(focus: focus)
    }

    /// Model-family picker, shown only for agents c11 pins a `--model` flag
    /// for. The empty tag means "inherit" (no flag injected); each family maps
    /// to `claude --model <family>`, resolving to that family's latest version.
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(String(localized: "settings.defaultAgent.model.label", defaultValue: "model"))
                    .font(.callout)
                Picker("", selection: $vm.model) {
                    Text(String(localized: "settings.defaultAgent.model.inherit",
                                defaultValue: "Inherit (agent default)"))
                        .tag("")
                    ForEach(ClaudeModelFamily.allCases) { family in
                        Text(family.displayName).tag(family.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("DefaultAgentModelPicker")
                Spacer()
            }
            Text(String(localized: "settings.defaultAgent.model.help",
                        defaultValue: "pins --model on launch, so agents launched here stay on this family even when your ambient Claude default changes. picks the family, not a version — new releases need no change. a model set in the command above wins."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Effort-level picker, shown only for agents c11 pins an `--effort` flag
    /// for. The empty tag means "inherit" (no flag injected); each case maps to
    /// `claude --effort <level>`.
    private var effortPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(String(localized: "settings.defaultAgent.effort.label", defaultValue: "effort"))
                    .font(.callout)
                Picker("", selection: $vm.effort) {
                    Text(String(localized: "settings.defaultAgent.effort.inherit",
                                defaultValue: "Inherit (agent default)"))
                        .tag("")
                    ForEach(ClaudeEffort.allCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("DefaultAgentEffortPicker")
                Spacer()
            }
            Text(String(localized: "settings.defaultAgent.effort.help",
                        defaultValue: "optional. pins --effort on launch so agents launched here run at this reasoning effort. leave on Inherit to keep the agent's ambient effort. higher levels may be limited by your plan."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var envOverridesDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showEnvOverrides.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showEnvOverrides ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 10)
                    Text(String(localized: "settings.defaultAgent.env.disclosure",
                                defaultValue: "environment overrides — advanced users only"))
                        .font(.callout)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("DefaultAgentEnvDisclosureButton")

            if showEnvOverrides {
                TextEditor(text: $vm.envOverridesText)
                    .frame(minHeight: 60, maxHeight: 120)
                    .font(.system(.body, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .accessibilityIdentifier("DefaultAgentEnvField")
                Text(String(localized: "settings.defaultAgent.env.help",
                            defaultValue: "one KEY=value per line. injected into the agent's process. leave empty unless you know why you want it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Per-agent string helpers

    private func perAgentHeading(for agent: AgentType) -> String {
        let format = String(localized: "settings.defaultAgent.subheading.format",
                            defaultValue: "Agent %@")
        return String(format: format, locale: Locale.current, agent.displayName)
    }

    private func commandHelp(for agent: AgentType) -> String {
        let format = String(localized: "settings.defaultAgent.command.help.format",
                            defaultValue: "the shell line that runs when we launch the %@ agent. you can include any parameters to match your specification.")
        return String(format: format, locale: Locale.current, agent.displayName)
    }
}
