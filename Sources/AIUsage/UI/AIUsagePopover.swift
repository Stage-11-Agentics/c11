import AppKit
import SwiftUI

struct AIUsagePopover: View {
    let provider: AIUsageProvider
    @ObservedObject var store: AIUsageAccountStore
    @ObservedObject var poller: AIUsagePoller
    @Binding var isPresented: Bool

    var onAdd: () -> Void
    var onEdit: (AIUsageAccount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusSection
            Divider()
            actionSection
        }
        .padding(14)
        .frame(width: 320)
    }

    private var providerAccounts: [AIUsageAccount] {
        store.accounts.filter { $0.providerId == provider.id }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(provider.statusSectionTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            let loaded = poller.statusLoaded[provider.id] ?? false
            let failed = poller.statusFetchFailed[provider.id] ?? false
            let succeeded = poller.statusHasSucceeded[provider.id] ?? false
            let incidents = poller.incidents[provider.id] ?? []

            if !loaded {
                Text(String(localized: "aiusage.status.loading", defaultValue: "Loading status..."))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else if failed && !succeeded {
                Text(String(localized: "aiusage.status.fetchFailed",
                            defaultValue: "Could not load status."))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else if incidents.isEmpty {
                Text(AIUsageStatusRanking.statusText(for: incidents))
                    .font(.system(size: 12))
                    .foregroundColor(.green)
            } else {
                ForEach(incidents) { incident in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(severityColor(incident.impact))
                            .frame(width: 6, height: 6)
                        Text(incident.name)
                            .font(.system(size: 12))
                            .lineLimit(2)
                    }
                }
            }

            if let url = provider.statusPageURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(String(localized: "aiusage.status.openPage",
                                defaultValue: "Open status page"))
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isPresented = false
                onAdd()
            } label: {
                Label(String(localized: "aiusage.add.button", defaultValue: "Add account"),
                      systemImage: "plus.circle")
            }
            .buttonStyle(.plain)

            ForEach(providerAccounts) { account in
                Button {
                    isPresented = false
                    onEdit(account)
                } label: {
                    Label(account.displayName, systemImage: "pencil.circle")
                }
                .buttonStyle(.plain)
            }

            Button {
                AIUsagePoller.shared.refreshNow()
            } label: {
                Label(String(localized: "aiusage.refreshNow",
                             defaultValue: "Refresh now"),
                      systemImage: "arrow.clockwise.circle")
            }
            .buttonStyle(.plain)
        }
    }

    private func severityColor(_ impact: String) -> Color {
        switch impact.lowercased() {
        case "critical": return .red
        case "major": return .red
        case "minor": return .orange
        case "maintenance": return .blue
        default: return .secondary
        }
    }
}
