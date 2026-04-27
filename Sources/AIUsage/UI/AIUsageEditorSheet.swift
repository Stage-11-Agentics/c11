import SwiftUI

struct AIUsageEditorSheet: View {
    let provider: AIUsageProvider
    let editingAccount: AIUsageAccount?
    let onClose: () -> Void

    @ObservedObject private var store = AIUsageAccountStore.shared
    @State private var displayName: String = ""
    @State private var values: [String: String] = [:]
    @State private var isLoadingExisting: Bool = false
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingAccount == nil
                 ? String(
                    localized: "aiusage.editor.title.add",
                    defaultValue: "Add account"
                 )
                 : String(
                    localized: "aiusage.editor.title.edit",
                    defaultValue: "Edit account"
                 ))
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "aiusage.editor.name", defaultValue: "Name"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(provider.displayName, text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLoadingExisting || isSaving)
            }

            ForEach(provider.credentialFields) { field in
                fieldEditor(for: field)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button(String(localized: "aiusage.editor.cancel", defaultValue: "Cancel")) {
                    onClose()
                }
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(String(localized: "aiusage.editor.save", defaultValue: "Save"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || isSaving)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .task { await loadExistingIfNeeded() }
    }

    @ViewBuilder
    private func fieldEditor(for field: AIUsageCredentialField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Group {
                if field.isSecret {
                    SecureField(field.placeholder, text: bindingFor(field))
                } else {
                    TextField(field.placeholder, text: bindingFor(field))
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(isLoadingExisting || isSaving)
            if let helpText = field.helpText {
                Text(helpText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func bindingFor(_ field: AIUsageCredentialField) -> Binding<String> {
        Binding(
            get: { values[field.id] ?? "" },
            set: { values[field.id] = $0 }
        )
    }

    private var canSave: Bool {
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        for field in provider.credentialFields {
            let value = values[field.id] ?? ""
            if field.isSecret && value.isEmpty { return false }
            if let validate = field.validate, !validate(value) {
                if field.isSecret || !value.isEmpty {
                    return false
                }
            }
        }
        return true
    }

    @MainActor
    private func loadExistingIfNeeded() async {
        guard let account = editingAccount else { return }
        displayName = account.displayName
        isLoadingExisting = true
        defer { isLoadingExisting = false }
        do {
            let secret = try await store.secret(for: account.id)
            // Only fill blanks; never clobber user keystrokes that may have
            // landed before the async load completed.
            for (key, value) in secret.fields {
                if (values[key] ?? "").isEmpty {
                    values[key] = value
                }
            }
        } catch let error as LocalizedError {
            errorMessage = error.errorDescription ?? String(
                localized: "aiusage.error.loadSecret",
                defaultValue: "Could not load saved credential."
            )
        } catch {
            errorMessage = String(
                localized: "aiusage.error.loadSecret",
                defaultValue: "Could not load saved credential."
            )
        }
    }

    @MainActor
    private func save() async {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let secret = AIUsageSecret(fields: fields)

        isSaving = true
        defer { isSaving = false }
        do {
            if let account = editingAccount {
                try await store.update(id: account.id, displayName: trimmedName, secret: secret)
            } else {
                try await store.add(providerId: provider.id, displayName: trimmedName, secret: secret)
            }
            AIUsagePoller.shared.refreshNow()
            onClose()
        } catch let storeError as AIUsageStoreError {
            errorMessage = storeError.errorDescription
        } catch let local as LocalizedError {
            errorMessage = local.errorDescription
        } catch {
            errorMessage = String(
                localized: "aiusage.error.fetchFailedGeneric",
                defaultValue: "Could not fetch usage."
            )
        }
    }
}
