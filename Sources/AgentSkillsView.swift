import SwiftUI
import Foundation
import AppKit

// MARK: - Shared state

/// Observable wrapper around `SkillInstaller` for SwiftUI views. The model
/// refreshes on demand and whenever the app is foregrounded.
@MainActor
final class AgentSkillsModel: ObservableObject {
    struct TargetRow: Identifiable {
        let id: String
        let target: SkillInstallerTarget
        let detected: Bool
        let destinationDir: URL
        let packages: [SkillInstallerPackageStatus]
        var hasOutdated: Bool {
            packages.contains { $0.state == .installedOutdated || $0.state == .installedNoManifest || $0.state == .schemaMismatch }
        }
        var anyInstalled: Bool {
            packages.contains { $0.state != .notInstalled }
        }
        var allCurrent: Bool {
            !packages.isEmpty && packages.allSatisfy { $0.state == .installedCurrent }
        }
    }

    @Published private(set) var sourceDir: URL?
    @Published private(set) var sourceError: String?
    @Published private(set) var rows: [TargetRow] = []
    @Published private(set) var loading: Bool = false
    @Published private(set) var lastActionMessage: String?

    private let home: URL
    private let fileManager: FileManager

    init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.home = home
        self.fileManager = fileManager
    }

    func refresh() {
        loading = true
        defer { loading = false }

        let executableURL = Bundle.main.executableURL
        guard let source = SkillInstaller.defaultSourceURL(executableURL: executableURL) else {
            sourceError = String(localized: "agentSkills.error.sourceNotFound", defaultValue: "Could not locate the bundled skills directory.")
            sourceDir = nil
            rows = []
            return
        }
        sourceError = nil
        sourceDir = source

        var newRows: [TargetRow] = []
        for target in SkillInstallerTarget.allCases {
            let detected = target.isDetected(home: home, fileManager: fileManager)
            var packages: [SkillInstallerPackageStatus] = []
            if detected {
                do {
                    packages = try SkillInstaller.status(
                        for: target,
                        home: home,
                        sourceDir: source,
                        fileManager: fileManager
                    )
                } catch {
                    packages = []
                }
            }
            newRows.append(TargetRow(
                id: target.rawValue,
                target: target,
                detected: detected,
                destinationDir: target.skillsDir(home: home),
                packages: packages
            ))
        }
        rows = newRows
    }

    func install(target: SkillInstallerTarget, force: Bool) {
        guard let source = sourceDir else { return }
        do {
            let result = try SkillInstaller.install(
                target: target,
                home: home,
                sourceDir: source,
                force: force,
                fileManager: fileManager
            )
            lastActionMessage = formatInstallMessage(result: result)
        } catch let err as SkillInstallerError {
            lastActionMessage = AgentSkillsLocalized.description(for: err, target: target)
        } catch {
            lastActionMessage = error.localizedDescription
        }
        refresh()
    }

    func remove(target: SkillInstallerTarget) {
        guard let source = sourceDir else { return }
        do {
            let result = try SkillInstaller.remove(
                target: target,
                home: home,
                sourceDir: source,
                fileManager: fileManager
            )
            lastActionMessage = formatRemoveMessage(result: result)
        } catch let err as SkillInstallerError {
            lastActionMessage = AgentSkillsLocalized.description(for: err, target: target)
        } catch {
            lastActionMessage = error.localizedDescription
        }
        refresh()
    }

    func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyManualCommandToPasteboard(target: SkillInstallerTarget) {
        guard let source = sourceDir else { return }
        let destRoot = target.skillsDir(home: home).path
        let snippet = "mkdir -p \"\(destRoot)\" && rsync -a \"\(source.path)/\" \"\(destRoot)/\""
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
        lastActionMessage = String(
            localized: "agentSkills.action.copied",
            defaultValue: "Copied install command to clipboard."
        )
    }

    private func formatInstallMessage(result: SkillInstallerApplyResult) -> String {
        var parts: [String] = []
        if !result.installed.isEmpty { parts.append(AgentSkillsLocalized.installedFragment(result.installed)) }
        if !result.refreshed.isEmpty { parts.append(AgentSkillsLocalized.refreshedFragment(result.refreshed)) }
        if !result.skipped.isEmpty { parts.append(AgentSkillsLocalized.skippedFragment(result.skipped)) }
        if parts.isEmpty { parts.append(AgentSkillsLocalized.noOpFragment()) }
        return AgentSkillsLocalized.envelope(target: result.target.displayName, body: parts.joined(separator: "; "))
    }

    private func formatRemoveMessage(result: SkillInstallerRemoveResult) -> String {
        if result.removed.isEmpty && result.skipped.isEmpty {
            return AgentSkillsLocalized.envelope(
                target: result.target.displayName,
                body: AgentSkillsLocalized.nothingToRemove()
            )
        }
        var parts: [String] = []
        if !result.removed.isEmpty { parts.append(AgentSkillsLocalized.removedFragment(result.removed)) }
        if !result.skipped.isEmpty { parts.append(AgentSkillsLocalized.skippedFragment(result.skipped)) }
        return AgentSkillsLocalized.envelope(target: result.target.displayName, body: parts.joined(separator: "; "))
    }
}

// MARK: - Localization helpers

/// Single point that knows how to turn action results and installer errors
/// into user-visible strings. Keeps `String(localized:)` call sites out of
/// the hot per-row format methods so xcstrings stays the source of truth.
enum AgentSkillsLocalized {
    static func envelope(target: String, body: String) -> String {
        let fmt = String(
            localized: "agentSkills.action.envelope",
            defaultValue: "%1$@ — %2$@"
        )
        return String(format: fmt, target, body)
    }

    static func installedFragment(_ items: [String]) -> String {
        let fmt = String(
            localized: "agentSkills.action.installedFragment",
            defaultValue: "installed: %@"
        )
        return String(format: fmt, items.joined(separator: ", "))
    }

    static func refreshedFragment(_ items: [String]) -> String {
        let fmt = String(
            localized: "agentSkills.action.refreshedFragment",
            defaultValue: "refreshed: %@"
        )
        return String(format: fmt, items.joined(separator: ", "))
    }

    static func skippedFragment(_ items: [String]) -> String {
        let fmt = String(
            localized: "agentSkills.action.skippedFragment",
            defaultValue: "skipped: %@"
        )
        return String(format: fmt, items.joined(separator: ", "))
    }

    static func removedFragment(_ items: [String]) -> String {
        let fmt = String(
            localized: "agentSkills.action.removedFragment",
            defaultValue: "removed: %@"
        )
        return String(format: fmt, items.joined(separator: ", "))
    }

    static func noOpFragment() -> String {
        String(
            localized: "agentSkills.action.noOp",
            defaultValue: "no-op"
        )
    }

    static func nothingToRemove() -> String {
        String(
            localized: "agentSkills.action.nothingToRemove",
            defaultValue: "nothing to remove"
        )
    }

    /// Maps `SkillInstallerError.Code` to a localized message. The underlying
    /// error's `path` is injected as `%@` so the operator sees what got
    /// refused. Keeps the core installer language-agnostic (CLI users still
    /// see the raw English message).
    static func description(for error: SkillInstallerError, target: SkillInstallerTarget) -> String {
        let path = error.path ?? ""
        switch error.code {
        case .noSourceFound:
            return String(
                localized: "agentSkills.error.sourceNotFound",
                defaultValue: "Could not locate the bundled skills directory."
            )
        case .sourceNotReadable:
            return String(
                format: String(
                    localized: "agentSkills.error.sourceNotReadable",
                    defaultValue: "Cannot read the bundled skills directory at %@."
                ),
                path
            )
        case .targetNotDetected:
            return String(
                format: String(
                    localized: "agentSkills.error.targetNotDetected",
                    defaultValue: "%@ is not installed — create its config directory first."
                ),
                target.displayName
            )
        case .destUnwritable:
            return String(
                format: String(
                    localized: "agentSkills.error.destUnwritable",
                    defaultValue: "Cannot write to %@. Check permissions."
                ),
                path
            )
        case .destNotManaged:
            return String(
                format: String(
                    localized: "agentSkills.error.destNotManaged",
                    defaultValue: "%@ already exists but is not a c11mux-managed skill. Use Update/Refresh to replace it."
                ),
                path
            )
        case .copyFailed:
            return String(
                format: String(
                    localized: "agentSkills.error.copyFailed",
                    defaultValue: "Could not copy the skill to %@."
                ),
                path
            )
        case .manifestMalformed:
            return String(
                format: String(
                    localized: "agentSkills.error.manifestMalformed",
                    defaultValue: "The bundled skills manifest at %@ is malformed."
                ),
                path
            )
        case .emptyPackageSet:
            return String(
                localized: "agentSkills.error.emptyPackageSet",
                defaultValue: "No installable skill packages were found. Reinstall c11mux."
            )
        }
    }
}

// MARK: - Settings pane

struct AgentSkillsSettingsSection: View {
    @StateObject private var model = AgentSkillsModel()
    @State private var showingOnboardingSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = model.sourceError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                rows
            }
            if let msg = model.lastActionMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            HStack {
                Button(String(localized: "agentSkills.button.runWizard", defaultValue: "Run Onboarding Wizard…")) {
                    showingOnboardingSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $showingOnboardingSheet) {
            AgentSkillsOnboardingSheet(onDismiss: {
                showingOnboardingSheet = false
                model.refresh()
            })
        }
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
            AgentSkillsRow(row: row, model: model)
            if index < model.rows.count - 1 {
                Rectangle()
                    .fill(Color(nsColor: NSColor.separatorColor).opacity(0.5))
                    .frame(height: 1)
            }
        }
    }
}

private struct AgentSkillsRow: View {
    let row: AgentSkillsModel.TargetRow
    @ObservedObject var model: AgentSkillsModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.target.displayName)
                        .font(.system(size: 13, weight: .medium))
                    statusChip
                }
                Text(row.destinationDir.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusChip: some View {
        let (label, color) = statusLabel()
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.13))
            )
    }

    private func statusLabel() -> (String, Color) {
        if !row.detected {
            return (String(localized: "agentSkills.status.notDetected", defaultValue: "not detected"), .secondary)
        }
        if row.hasOutdated {
            return (String(localized: "agentSkills.status.updateAvailable", defaultValue: "update available"), .orange)
        }
        if row.allCurrent {
            return (String(localized: "agentSkills.status.installed", defaultValue: "installed"), .green)
        }
        if row.anyInstalled {
            return (String(localized: "agentSkills.status.partial", defaultValue: "partial"), .orange)
        }
        return (String(localized: "agentSkills.status.notInstalled", defaultValue: "not installed"), .secondary)
    }

    @ViewBuilder
    private var trailingButtons: some View {
        HStack(spacing: 6) {
            if !row.detected {
                // Nothing to do; surface a minor affordance to reveal the bundled source.
                Button(String(localized: "agentSkills.button.revealSource", defaultValue: "Reveal Skill")) {
                    if let src = model.sourceDir {
                        model.revealInFinder(url: src)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if row.target == .claude {
                claudeButtons
            } else {
                operatorDirectedButtons
            }
        }
    }

    @ViewBuilder
    private var claudeButtons: some View {
        if row.allCurrent {
            Button(String(localized: "agentSkills.button.refresh", defaultValue: "Refresh")) {
                model.install(target: row.target, force: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(String(localized: "agentSkills.button.remove", defaultValue: "Remove")) {
                model.remove(target: row.target)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if row.anyInstalled {
            Button(String(localized: "agentSkills.button.update", defaultValue: "Update")) {
                model.install(target: row.target, force: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button(String(localized: "agentSkills.button.remove", defaultValue: "Remove")) {
                model.remove(target: row.target)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button(String(localized: "agentSkills.button.install", defaultValue: "Install")) {
                model.install(target: row.target, force: false)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var operatorDirectedButtons: some View {
        // For non-Claude tools, prefer operator-driven installation (clipboard
        // snippet + Finder reveal). The user can still use the Install/Refresh
        // buttons if they explicitly want c11mux to copy into that tool's dir.
        Button(String(localized: "agentSkills.button.copyCommand", defaultValue: "Copy Command")) {
            model.copyManualCommandToPasteboard(target: row.target)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        if row.anyInstalled {
            Button(String(localized: "agentSkills.button.update", defaultValue: "Update")) {
                model.install(target: row.target, force: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(String(localized: "agentSkills.button.remove", defaultValue: "Remove")) {
                model.remove(target: row.target)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button(String(localized: "agentSkills.button.install", defaultValue: "Install")) {
                model.install(target: row.target, force: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - First-run onboarding sheet

/// Sheet shown once, after the welcome flow, when c11mux detects Claude Code
/// but has never offered a skill install. User can consent, skip (this run),
/// or defer forever (don't ask again). Settings exposes the same controls, so
/// "don't ask again" is not a dead-end.
struct AgentSkillsOnboardingSheet: View {
    let onDismiss: () -> Void
    @StateObject private var model = AgentSkillsModel()

    @State private var claudeOptIn: Bool = true
    @State private var codexOptIn: Bool = false
    @State private var kimiOptIn: Bool = false
    @State private var opencodeOptIn: Bool = false

    init(onDismiss: @escaping () -> Void = {}) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "agentSkills.onboarding.title", defaultValue: "Teach your agents about c11mux"))
                .font(.system(size: 18, weight: .semibold))
            Text(String(localized: "agentSkills.onboarding.body", defaultValue: "Agents only know about c11mux's CLI and sidebar metadata when they've read the c11mux skill file. Pick which agents should get it — you can change this any time in Settings → Agent Skills."))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.rows) { row in
                    onboardingRow(row: row)
                }
            }
            .padding(.vertical, 2)

            if let msg = model.lastActionMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Button(String(localized: "agentSkills.onboarding.dontAsk", defaultValue: "Don't ask again")) {
                    UserDefaults.standard.set(true, forKey: AgentSkillsOnboarding.sheetShownKey)
                    onDismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(String(localized: "agentSkills.onboarding.later", defaultValue: "Later")) {
                    AgentSkillsOnboarding.markDismissedThisLaunch()
                    onDismiss()
                }
                .buttonStyle(.bordered)

                Button(String(localized: "agentSkills.onboarding.install", defaultValue: "Install")) {
                    applySelection()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!anySelected)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { model.refresh() }
    }

    private var anySelected: Bool {
        claudeOptIn || codexOptIn || kimiOptIn || opencodeOptIn
    }

    @ViewBuilder
    private func onboardingRow(row: AgentSkillsModel.TargetRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(isOn: optInBinding(for: row.target)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.target.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Text(detectionLabel(for: row))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!row.detected)
        }
    }

    private func detectionLabel(for row: AgentSkillsModel.TargetRow) -> String {
        if !row.detected {
            return String(
                localized: "agentSkills.onboarding.notDetected",
                defaultValue: "Not detected — install the agent tool first, or enable from Settings later."
            )
        }
        if row.allCurrent {
            return String(
                localized: "agentSkills.onboarding.alreadyInstalled",
                defaultValue: "Already installed and up to date."
            )
        }
        return row.destinationDir.path
    }

    private func optInBinding(for target: SkillInstallerTarget) -> Binding<Bool> {
        switch target {
        case .claude: return $claudeOptIn
        case .codex: return $codexOptIn
        case .kimi: return $kimiOptIn
        case .opencode: return $opencodeOptIn
        }
    }

    private func applySelection() {
        let selections: [(SkillInstallerTarget, Bool)] = [
            (.claude, claudeOptIn),
            (.codex, codexOptIn),
            (.kimi, kimiOptIn),
            (.opencode, opencodeOptIn),
        ]
        for (target, selected) in selections where selected {
            guard let row = model.rows.first(where: { $0.target == target }), row.detected else { continue }
            model.install(target: target, force: false)
        }
        UserDefaults.standard.set(true, forKey: AgentSkillsOnboarding.sheetShownKey)
        onDismiss()
    }
}

// MARK: - Onboarding plumbing

enum AgentSkillsOnboarding {
    /// Persistent "Don't ask again" flag. Set only by the explicit button in
    /// the onboarding sheet; never by a plain close or "Later" click.
    static let sheetShownKey = "cmuxAgentSkillsOnboardingShown"

    /// In-memory flag scoped to the current app launch. Set when the user
    /// dismisses the sheet by clicking "Later", or by hitting the window's
    /// close button. Prevents another welcome workspace from re-triggering
    /// the sheet in the same run without promoting the persistent
    /// "don't ask again" state.
    @MainActor private static var _dismissedThisLaunch: Bool = false

    @MainActor static func markDismissedThisLaunch() {
        _dismissedThisLaunch = true
    }

    @MainActor static var dismissedThisLaunch: Bool {
        _dismissedThisLaunch
    }

    /// Should the onboarding sheet be offered on this launch? True iff a
    /// claude config dir exists AND at least one bundled package is not yet
    /// installed in it AND the user hasn't already dismissed the sheet.
    @MainActor static func shouldPresent(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        if defaults.bool(forKey: sheetShownKey) { return false }
        if _dismissedThisLaunch { return false }
        let target = SkillInstallerTarget.claude
        guard target.isDetected(home: home, fileManager: fileManager) else { return false }
        guard let source = SkillInstaller.defaultSourceURL(executableURL: Bundle.main.executableURL) else { return false }
        guard let statuses = try? SkillInstaller.status(for: target, home: home, sourceDir: source, fileManager: fileManager) else {
            return false
        }
        return statuses.contains { $0.state == .notInstalled || $0.state == .installedOutdated }
    }
}
