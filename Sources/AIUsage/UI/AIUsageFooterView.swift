import SwiftUI

struct AIUsageFooterView: View {
    @ObservedObject private var store = AIUsageAccountStore.shared
    @ObservedObject private var poller = AIUsagePoller.shared
    @ObservedObject private var colorSettings = AIUsageColorSettings.shared

    @State private var presentedProviderId: String?
    @State private var collapsed: [String: Bool] = [:]

    var body: some View {
        let sections = providerSections
        if sections.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sections, id: \.provider.id) { section in
                    providerSection(section)
                }
            }
            .accessibilityLabel(String(
                localized: "aiusage.footer.accessibility",
                defaultValue: "AI usage panel"
            ))
        }
    }

    private struct Section {
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

    @ViewBuilder
    private func providerSection(_ section: Section) -> some View {
        let collapsedKey = "c11.aiusage.collapsed.\(section.provider.id)"
        let isCollapsed = collapsed[section.provider.id]
            ?? UserDefaults.standard.bool(forKey: collapsedKey)

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    let next = !(isCollapsed)
                    collapsed[section.provider.id] = next
                    UserDefaults.standard.set(next, forKey: collapsedKey)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text(section.provider.displayName)
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
                    presentedProviderId = section.provider.id
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .popover(
                    isPresented: Binding(
                        get: { presentedProviderId == section.provider.id },
                        set: { open in
                            if !open && presentedProviderId == section.provider.id {
                                presentedProviderId = nil
                            }
                        }
                    ),
                    arrowEdge: .top
                ) {
                    AIUsagePopover(
                        provider: section.provider,
                        store: store,
                        poller: poller,
                        isPresented: Binding(
                            get: { presentedProviderId == section.provider.id },
                            set: { open in
                                if !open && presentedProviderId == section.provider.id {
                                    presentedProviderId = nil
                                }
                            }
                        ),
                        onAdd: {},
                        onEdit: { _ in }
                    )
                }
            }

            if !isCollapsed {
                ForEach(section.accounts) { account in
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
                bar(label: String(localized: "aiusage.window.session", defaultValue: "Session"),
                    window: snapshot.session,
                    isSession: true)
                bar(label: String(localized: "aiusage.window.week", defaultValue: "Week"),
                    window: snapshot.week,
                    isSession: false)
            } else if poller.isRefreshing {
                Text(String(localized: "aiusage.status.loading", defaultValue: "Loading status..."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func bar(label: String, window: AIUsageWindow, isSession: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
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
            Text("\(window.utilization)%")
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}
