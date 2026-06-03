import SwiftUI
import Combine

/// View-model for the "default agent" Settings section.
@MainActor
final class DefaultAgentSettingsViewModel: ObservableObject {
    @Published var defaultAgent: AgentType
    @Published var editingAgent: AgentType
    @Published var command: String
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
        $initialPrompt.dropFirst().sink { [weak self] _ in self?.persistFields() }.store(in: &cancellables)
        $envOverridesText.dropFirst().sink { [weak self] _ in self?.persistFields() }.store(in: &cancellables)
    }

    private func loadFields(for agent: AgentType) {
        suppressSave = true
        defer { suppressSave = false }
        let entry = store.current.config(for: agent)
        command = entry.command
        initialPrompt = entry.initialPrompt
        envOverridesText = entry.envOverridesText
    }

    private func persistFields() {
        guard !suppressSave else { return }
        let captured = editingAgent
        let snapshot = AgentConfig(
            command: command,
            initialPrompt: initialPrompt,
            envOverridesText: envOverridesText
        )
        store.update(captured) { $0 = snapshot }
    }

    /// Reset all fields for the currently-edited agent to factory defaults.
    func resetEditingAgent() {
        suppressSave = true
        let factory = AgentConfig.factory(for: editingAgent)
        command = factory.command
        initialPrompt = factory.initialPrompt
        envOverridesText = factory.envOverridesText
        suppressSave = false
        store.update(editingAgent) { $0 = factory }
    }
}

struct DefaultAgentSettingsSection: View {
    @StateObject private var vm = DefaultAgentSettingsViewModel()
    @State private var showEnvOverrides = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
