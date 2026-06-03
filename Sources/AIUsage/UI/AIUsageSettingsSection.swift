import SwiftUI

struct AIUsageSettingsSection: View {
    @ObservedObject var store: AIUsageAccountStore
    @ObservedObject var poller: AIUsagePoller
    @ObservedObject var colorSettings: AIUsageColorSettings

    @Binding var editorRequest: AIUsageEditorRequest?
    @Binding var accountToRemove: AIUsageAccount?
    @Binding var showRemoveConfirmation: Bool

    @AppStorage("c11.aiusage.visible") private var isVisible: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: String(
                localized: "aiusage.section.title",
                defaultValue: "AI Usage Monitoring"
            ))

            SettingsCard {
                SettingsCardRow(
                    String(
                        localized: "aiusage.settings.showInSidebar",
                        defaultValue: "Show in sidebar"
                    )
                ) {
                    Toggle("", isOn: $isVisible)
                        .labelsHidden()
                }
                SettingsCardDivider()
                ForEach(store.accounts.filter { provider(for: $0) != nil }) { account in
                    accountRow(account)
                    SettingsCardDivider()
                }
                addRow
            }

            ForEach(orphanAccounts) { account in
                orphanCard(for: account)
            }

            SettingsSectionHeader(title: String(
                localized: "aiusage.colors.section.title",
                defaultValue: "Usage bar colors"
            ))

            SettingsCard {
                colorRow(
                    title: String(
                        localized: "aiusage.colors.low",
                        defaultValue: "Low"
                    ),
                    hex: $colorSettings.lowColorHex
                )
                SettingsCardDivider()
                colorRow(
                    title: String(
                        localized: "aiusage.colors.mid",
                        defaultValue: "Mid"
                    ),
                    hex: $colorSettings.midColorHex
                )
                SettingsCardDivider()
                colorRow(
                    title: String(
                        localized: "aiusage.colors.high",
                        defaultValue: "High"
                    ),
                    hex: $colorSettings.highColorHex
                )
                SettingsCardDivider()
                thresholdRow
                SettingsCardDivider()
                interpolateRow
                SettingsCardDivider()
                resetRow
            }
        }
    }

    private var orphanAccounts: [AIUsageAccount] {
        let known = Set(AIUsageRegistry.ui.map { $0.id })
        return store.accounts.filter { !known.contains($0.providerId) }
    }

    private func provider(for account: AIUsageAccount) -> AIUsageProvider? {
        AIUsageRegistry.provider(id: account.providerId)
    }

    private func accountRow(_ account: AIUsageAccount) -> some View {
        let provider = provider(for: account)
        let summary = summaryText(for: account)
        return SettingsCardRow(
            account.displayName,
            subtitle: summary
        ) {
            HStack(spacing: 6) {
                Button(String(localized: "aiusage.edit.button", defaultValue: "Edit")) {
                    if let provider {
                        editorRequest = AIUsageEditorRequest(provider: provider, account: account)
                    }
                }
                Button(String(localized: "aiusage.remove.button", defaultValue: "Remove"),
                       role: .destructive) {
                    accountToRemove = account
                    showRemoveConfirmation = true
                }
            }
        }
    }

    private var addRow: some View {
        let providers = AIUsageRegistry.ui
        return SettingsCardRow(
            String(
                localized: "aiusage.add.menu.label",
                defaultValue: "Add an AI account"
            ),
            subtitle: nil
        ) {
            if providers.count > 1 {
                Menu {
                    ForEach(providers, id: \.id) { provider in
                        Button(provider.displayName) {
                            editorRequest = AIUsageEditorRequest(provider: provider, account: nil)
                        }
                    }
                } label: {
                    Label(
                        String(localized: "aiusage.add.button", defaultValue: "Add account"),
                        systemImage: "plus"
                    )
                }
            } else if let only = providers.first {
                Button {
                    editorRequest = AIUsageEditorRequest(provider: only, account: nil)
                } label: {
                    Label(
                        String(localized: "aiusage.add.button", defaultValue: "Add account"),
                        systemImage: "plus"
                    )
                }
            }
        }
    }

    private func orphanCard(for account: AIUsageAccount) -> some View {
        SettingsCard {
            SettingsCardRow(
                String(
                    localized: "aiusage.settings.unknownProvider",
                    defaultValue: "Unknown provider"
                ),
                subtitle: String(
                    localized: "aiusage.settings.unknownProvider.subtitle",
                    defaultValue: "This provider is not available in this build. Remove the account to clear the saved credential."
                )
            ) {
                Button(String(localized: "aiusage.remove.button", defaultValue: "Remove"),
                       role: .destructive) {
                    accountToRemove = account
                    showRemoveConfirmation = true
                }
            }
        }
    }

    private func colorRow(title: String, hex: Binding<String>) -> some View {
        SettingsCardRow(title) {
            ColorPicker("", selection: Binding(
                get: { Color(usageHex: hex.wrappedValue) ?? .green },
                set: { hex.wrappedValue = $0.usageHexString }
            ))
            .labelsHidden()
        }
    }

    private var thresholdRow: some View {
        SettingsCardRow(
            String(
                localized: "aiusage.colors.thresholds",
                defaultValue: "Thresholds"
            ),
            subtitle: thresholdSubtitle
        ) {
            HStack(spacing: 6) {
                Stepper(
                    value: Binding(
                        get: { colorSettings.lowMidThreshold },
                        set: { colorSettings.setThresholds(low: $0, high: colorSettings.midHighThreshold) }
                    ),
                    in: 1...98
                ) {
                    Text("\(colorSettings.lowMidThreshold)")
                }
                .labelsHidden()
                Stepper(
                    value: Binding(
                        get: { colorSettings.midHighThreshold },
                        set: { colorSettings.setThresholds(low: colorSettings.lowMidThreshold, high: $0) }
                    ),
                    in: 2...99
                ) {
                    Text("\(colorSettings.midHighThreshold)")
                }
                .labelsHidden()
            }
        }
    }

    private var thresholdSubtitle: String {
        let format = String(
            localized: "aiusage.colors.thresholds.subtitle",
            defaultValue: "Low/mid below %lld%%, mid/high below %lld%%."
        )
        return String(format: format, locale: .current,
                      colorSettings.lowMidThreshold,
                      colorSettings.midHighThreshold)
    }

    private var interpolateRow: some View {
        SettingsCardRow(
            String(
                localized: "aiusage.colors.interpolate",
                defaultValue: "Smooth interpolation"
            )
        ) {
            Toggle("", isOn: $colorSettings.interpolate)
                .labelsHidden()
        }
    }

    private var resetRow: some View {
        SettingsCardRow(
            String(
                localized: "aiusage.colors.reset",
                defaultValue: "Reset to defaults"
            )
        ) {
            Button(String(localized: "aiusage.colors.reset", defaultValue: "Reset to defaults")) {
                colorSettings.resetToDefaults()
            }
        }
    }

    private func summaryText(for account: AIUsageAccount) -> String? {
        if let error = poller.fetchErrors[account.id] {
            return error
        }
        guard let snapshot = poller.snapshots[account.id] else {
            return nil
        }
        let format = String(
            localized: "aiusage.settings.summary",
            defaultValue: "Session %lld%% \u{00B7} Week %lld%%"
        )
        return String(format: format, locale: .current,
                      snapshot.session.utilization,
                      snapshot.week.utilization)
    }
}
