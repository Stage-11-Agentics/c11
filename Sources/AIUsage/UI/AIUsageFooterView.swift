import SwiftUI

struct AIUsageFooterView: View {
    @ObservedObject private var store = AIUsageAccountStore.shared
    @ObservedObject private var poller = AIUsagePoller.shared
    @ObservedObject private var colorSettings = AIUsageColorSettings.shared

    @State private var presentedProviderId: String?
    @State private var editorRequest: AIUsageEditorRequest?

    var body: some View {
        let sections = providerSections
        if sections.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sections, id: \.provider.id) { section in
                    AIUsageFooterProviderSection(
                        provider: section.provider,
                        accounts: section.accounts,
                        store: store,
                        poller: poller,
                        colorSettings: colorSettings,
                        presentedProviderId: $presentedProviderId,
                        editorRequest: $editorRequest
                    )
                }
            }
            .accessibilityLabel(String(
                localized: "aiusage.footer.accessibility",
                defaultValue: "AI usage panel"
            ))
            .sheet(item: $editorRequest) { request in
                AIUsageEditorSheet(
                    provider: request.provider,
                    editingAccount: request.account,
                    onClose: { editorRequest = nil }
                )
            }
        }
    }

    fileprivate struct Section {
        let provider: AIUsageProvider
        let accounts: [AIUsageAccount]
    }

    private var providerSections: [Section] {
        var byProvider: [String: [AIUsageAccount]] = [:]
        for account in store.accounts {
            byProvider[account.providerId, default: []].append(account)
        }
        return AIUsageRegistry.ui.compactMap { provider in
            guard let accounts = byProvider[provider.id], !accounts.isEmpty else {
                return nil
            }
            return Section(provider: provider, accounts: accounts)
        }
    }

    static func bar(label: String,
                    window: AIUsageWindow,
                    isSession: Bool,
                    colorSettings: AIUsageColorSettings) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)

            if window.utilization == 0 && window.costUSD > 0 {
                Text(String(format: "$%.2f", window.costUSD))
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundColor(.secondary)
            } else {
                GeometryReader { geo in
                    let width = max(0, geo.size.width)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.18))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colorSettings.color(for: window.utilization))
                            .frame(width: width * CGFloat(window.utilization) / 100.0)
                    }
                }
                .frame(height: 6)
                HStack(spacing: 4) {
                    Text("\(window.utilization)%")
                        .font(.system(size: 10, weight: .regular).monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    if window.costUSD > 0 {
                        Text(String(format: "$%.2f", window.costUSD))
                            .font(.system(size: 9, weight: .regular).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let resetText = AIUsageFooterView.resetCountdownText(window: window, isSession: isSession) {
                Text(resetText)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(String(
                        localized: "aiusage.reset.accessibility",
                        defaultValue: "Resets"
                    ))
            }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func resetCountdownText(window: AIUsageWindow, isSession: Bool, now: Date = Date()) -> String? {
        let label = providerUsageResetLabel(window: window, isSession: isSession, now: now)
        if case .resetsAt(let date) = label {
            let format = String(
                localized: "aiusage.reset.resetsIn",
                defaultValue: "resets %@"
            )
            let relative = relativeFormatter.localizedString(for: date, relativeTo: now)
            return String(format: format, locale: .current, relative)
        }
        return nil
    }
}

private struct AIUsageFooterProviderSection: View {
    let provider: AIUsageProvider
    let accounts: [AIUsageAccount]
    @ObservedObject var store: AIUsageAccountStore
    @ObservedObject var poller: AIUsagePoller
    @ObservedObject var colorSettings: AIUsageColorSettings
    @Binding var presentedProviderId: String?
    @Binding var editorRequest: AIUsageEditorRequest?

    @AppStorage private var isCollapsed: Bool

    init(provider: AIUsageProvider,
         accounts: [AIUsageAccount],
         store: AIUsageAccountStore,
         poller: AIUsagePoller,
         colorSettings: AIUsageColorSettings,
         presentedProviderId: Binding<String?>,
         editorRequest: Binding<AIUsageEditorRequest?>) {
        self.provider = provider
        self.accounts = accounts
        self.store = store
        self.poller = poller
        self.colorSettings = colorSettings
        self._presentedProviderId = presentedProviderId
        self._editorRequest = editorRequest
        self._isCollapsed = AppStorage(
            wrappedValue: false,
            "c11.aiusage.collapsed.\(provider.id)"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    isCollapsed.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text(provider.displayName)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed
                                    ? String(localized: "aiusage.header.expand",
                                             defaultValue: "Expand")
                                    : String(localized: "aiusage.header.collapse",
                                             defaultValue: "Collapse"))

                Spacer()

                Button {
                    presentedProviderId = provider.id
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .popover(
                    isPresented: Binding(
                        get: { presentedProviderId == provider.id },
                        set: { open in
                            if !open && presentedProviderId == provider.id {
                                presentedProviderId = nil
                            }
                        }
                    ),
                    arrowEdge: .top
                ) {
                    AIUsagePopover(
                        provider: provider,
                        store: store,
                        poller: poller,
                        isPresented: Binding(
                            get: { presentedProviderId == provider.id },
                            set: { open in
                                if !open && presentedProviderId == provider.id {
                                    presentedProviderId = nil
                                }
                            }
                        ),
                        onAdd: {
                            editorRequest = AIUsageEditorRequest(provider: provider, account: nil)
                        },
                        onEdit: { account in
                            editorRequest = AIUsageEditorRequest(provider: provider, account: account)
                        }
                    )
                }
            }

            if !isCollapsed {
                ForEach(accounts) { account in
                    accountRow(account)
                }
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: AIUsageAccount) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundColor(.primary)

            if let message = poller.fetchErrors[account.id] {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            } else if let snapshot = poller.snapshots[account.id] {
                AIUsageFooterView.bar(
                    label: String(localized: "aiusage.window.session", defaultValue: "Session"),
                    window: snapshot.session,
                    isSession: true,
                    colorSettings: colorSettings
                )
                AIUsageFooterView.bar(
                    label: String(localized: "aiusage.window.week", defaultValue: "Week"),
                    window: snapshot.week,
                    isSession: false,
                    colorSettings: colorSettings
                )
            } else if poller.isRefreshing {
                Text(String(localized: "aiusage.status.loading", defaultValue: "Loading status..."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
