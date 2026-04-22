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
        let statusError: String?
        let sharedWithTarget: SkillInstallerTarget?
        var hasOutdated: Bool {
            packages.contains { $0.state == .installedOutdated || $0.state == .installedNoManifest || $0.state == .schemaMismatch }
        }
        var needsInstallOrUpdate: Bool {
            !isSharedDestination && !packages.isEmpty && packages.contains { $0.state == .notInstalled || $0.state == .installedOutdated }
        }
        var anyInstalled: Bool {
            packages.contains { $0.state != .notInstalled }
        }
        var allCurrent: Bool {
            !packages.isEmpty && packages.allSatisfy { $0.state == .installedCurrent }
        }
        var sourceVersionLabel: String? {
            let versions = Set(packages.map { $0.package.version }.filter { !$0.isEmpty && $0 != "0" })
            guard !versions.isEmpty else { return nil }
            return versions.sorted().map { "v\($0)" }.joined(separator: ", ")
        }
        var isSharedDestination: Bool {
            sharedWithTarget != nil
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

    /// Snapshot of a completed off-main refresh. Carried back to the main
    /// actor via an `async` hop before publishing.
    struct RefreshSnapshot: Sendable {
        let sourceDir: URL?
        let sourceError: String?
        let rows: [TargetRow]
    }

    func refresh() {
        loading = true
        let home = self.home
        let fileManager = self.fileManager
        let executableURL = Bundle.main.executableURL
        Task.detached(priority: .userInitiated) {
            let snapshot = AgentSkillsModel.computeSnapshot(
                executableURL: executableURL,
                home: home,
                fileManager: fileManager
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sourceDir = snapshot.sourceDir
                self.sourceError = snapshot.sourceError
                self.rows = snapshot.rows
                self.loading = false
            }
        }
    }

    /// Filesystem + hashing happen off-main. Declared `nonisolated` so it
    /// can run from a detached task without hopping back through the
    /// main-actor-isolated instance.
    nonisolated static func computeSnapshot(
        executableURL: URL?,
        home: URL,
        fileManager: FileManager
    ) -> RefreshSnapshot {
        guard let source = SkillInstaller.defaultSourceURL(executableURL: executableURL) else {
            return RefreshSnapshot(
                sourceDir: nil,
                sourceError: String(localized: "agentSkills.error.sourceNotFound", defaultValue: "Couldn't find the bundled skills directory."),
                rows: []
            )
        }
        var newRows: [TargetRow] = []
        var sharedOwnersByTarget: [SkillInstallerTarget: SkillInstallerTarget] = [:]
        var ownerByResolvedDestination: [String: SkillInstallerTarget] = [:]
        for target in SkillInstallerTarget.allCases {
            guard target.isDetected(home: home, fileManager: fileManager) else { continue }
            let destination = target.skillsDir(home: home)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let resolvedPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
            if let owner = ownerByResolvedDestination[resolvedPath] {
                sharedOwnersByTarget[target] = owner
            } else {
                ownerByResolvedDestination[resolvedPath] = target
            }
        }
        for target in SkillInstallerTarget.allCases {
            let detected = target.isDetected(home: home, fileManager: fileManager)
            var packages: [SkillInstallerPackageStatus] = []
            var statusError: String? = nil
            if detected {
                do {
                    packages = try SkillInstaller.status(
                        for: target,
                        home: home,
                        sourceDir: source,
                        fileManager: fileManager
                    )
                } catch let err as SkillInstallerError {
                    statusError = AgentSkillsLocalized.description(for: err, target: target)
                } catch {
                    statusError = error.localizedDescription
                }
            }
            newRows.append(TargetRow(
                id: target.rawValue,
                target: target,
                detected: detected,
                destinationDir: target.skillsDir(home: home),
                packages: packages,
                statusError: statusError,
                sharedWithTarget: sharedOwnersByTarget[target]
            ))
        }
        return RefreshSnapshot(sourceDir: source, sourceError: nil, rows: newRows)
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

    var primarySkillURL: URL? {
        sourceDir
    }

    func revealPrimarySkillInFinder() {
        guard let url = primarySkillURL else { return }
        revealInFinder(url: url)
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
                defaultValue: "Couldn't find the bundled skills directory."
            )
        case .sourceNotReadable:
            return String(
                format: String(
                    localized: "agentSkills.error.sourceNotReadable",
                    defaultValue: "Can't read the bundled skills directory at %@."
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
                    defaultValue: "Can't write to %@. Check permissions."
                ),
                path
            )
        case .destNotManaged:
            return String(
                format: String(
                    localized: "agentSkills.error.destNotManaged",
                    defaultValue: "%@ already exists but is not a c11-managed skill. Use Update/Refresh to replace it."
                ),
                path
            )
        case .copyFailed:
            return String(
                format: String(
                    localized: "agentSkills.error.copyFailed",
                    defaultValue: "Couldn't copy the skill to %@."
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
                defaultValue: "No installable skill packages were found. Reinstall c11."
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
                Text(rowDetailText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let err = row.statusError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        if row.isSharedDestination {
            return (String(localized: "agentSkills.status.shared", defaultValue: "shared"), .green)
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

    private var rowDetailText: String {
        if let sharedWithTarget = row.sharedWithTarget {
            let format = String(
                localized: "agentSkills.status.sharedWith",
                defaultValue: "Uses the %@ skill files"
            )
            return String(format: format, sharedWithTarget.displayName)
        }
        return row.destinationDir.path
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
            } else if row.isSharedDestination {
                Button(String(localized: "agentSkills.button.revealFolder", defaultValue: "Reveal Folder")) {
                    model.revealInFinder(url: row.destinationDir)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                skillManagementButtons
            }
        }
    }

    @ViewBuilder
    private var skillManagementButtons: some View {
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
}

// MARK: - First-run onboarding sheet

/// Sheet shown once, after the welcome flow, when c11 detects an agent
/// environment that is missing or running an older c11 skill set. User can
/// consent, skip (this run), or defer forever (don't ask again). Settings
/// exposes the same controls, so "don't ask again" is not a dead-end.
struct AgentSkillsOnboardingSheet: View {
    let onDismiss: () -> Void
    @StateObject private var model = AgentSkillsModel()

    @State private var claudeOptIn: Bool = false
    @State private var codexOptIn: Bool = false
    @State private var kimiOptIn: Bool = false
    @State private var opencodeOptIn: Bool = false
    @State private var initializedDefaultOptIns: Bool = false
    @State private var selectedAction: AgentSkillsOnboardingAction = .install

    init(onDismiss: @escaping () -> Void = {}) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            installSection

            if let msg = model.lastActionMessage {
                Text(msg)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(BrandColors.whiteSwiftUI.opacity(0.68))
            }

            learnMoreSection
            footer
        }
        .padding(24)
        .frame(width: 540)
        .background(OnboardingKeyboardMonitor(
            onMove: { direction in
                selectedAction = AgentSkillsOnboardingAction.moved(from: selectedAction, direction: direction)
            },
            onActivate: { activateSelectedAction() },
            onCancel: { installLater() }
        ))
        .environment(\.colorScheme, .dark)
        .onAppear { model.refresh() }
        .onReceive(model.$rows) { rows in
            guard !initializedDefaultOptIns, !rows.isEmpty else { return }
            applyDefaultOptIns(rows: rows)
            initializedDefaultOptIns = true
        }
    }

    private var anySelected: Bool {
        initializedDefaultOptIns && (claudeOptIn || codexOptIn || kimiOptIn || opencodeOptIn)
    }

    private var hasActionNeeded: Bool {
        detectedRows.contains { $0.needsInstallOrUpdate }
    }

    private var primaryActionDisabled: Bool {
        detectedRows.isEmpty || (hasActionNeeded && !anySelected)
    }

    private var primaryActionTitle: String {
        if !detectedRows.isEmpty && !hasActionNeeded {
            return String(localized: "agentSkills.onboarding.allSet", defaultValue: "All Set")
        }
        return String(localized: "agentSkills.onboarding.install", defaultValue: "Teach it")
    }

    private var detectedRows: [AgentSkillsModel.TargetRow] {
        model.rows.filter(\.detected)
    }

    private var notDetectedRows: [AgentSkillsModel.TargetRow] {
        model.rows.filter { !$0.detected }
    }

    private var detectedTargetList: String {
        let names = detectedRows.map { $0.target.displayName }
        return ListFormatter.localizedString(byJoining: names)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "agentSkills.onboarding.title", defaultValue: "Your agent doesn't know c11 yet."))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)

            Text(headerBody)
                .font(.system(size: 12, weight: .regular))
                .lineSpacing(2)
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerBody: String {
        if detectedRows.isEmpty {
            return String(
                localized: "agentSkills.onboarding.body.detecting",
                defaultValue: "The skill is how it learns. One file. After that, your agent splits panes, drives the browser, opens markdown surfaces, and reports progress to the sidebar — without you in the loop for routine moves."
            )
        }
        let format = String(
            localized: "agentSkills.onboarding.body.detected",
            defaultValue: "The skill is how it learns. One file in %@. After that, your agent splits panes, drives the browser, opens markdown surfaces, and reports progress to the sidebar — without you in the loop for routine moves."
        )
        return String(format: format, detectedTargetList)
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(String(localized: "agentSkills.onboarding.installSection", defaultValue: "Install into"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.62))

            if detectedRows.isEmpty {
                Text(String(localized: "agentSkills.onboarding.noDetectedTools", defaultValue: "Nothing detected yet. Install Claude Code, Codex, or another supported agent, then re-open this from Settings → Agent Skills."))
                    .font(.system(size: 12))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.68))
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(detectedRows.enumerated()), id: \.element.id) { index, row in
                        onboardingRow(row: row)
                        if index < detectedRows.count - 1 {
                            Rectangle()
                                .fill(BrandColors.ruleSwiftUI.opacity(0.7))
                                .frame(height: 1)
                                .padding(.leading, 30)
                        }
                    }
                }
            }

            if !notDetectedRows.isEmpty {
                Text(notDetectedSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.48))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func onboardingRow(row: AgentSkillsModel.TargetRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: optInBinding(for: row.target)) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!row.detected)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(row.target.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(row.detected ? BrandColors.whiteSwiftUI : BrandColors.whiteSwiftUI.opacity(0.42))
                    if let version = row.sourceVersionLabel {
                        Text(version)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BrandColors.goldSwiftUI)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(BrandColors.goldFaintSwiftUI)
                            )
                    }
                }
                Text(detectionLabel(for: row))
                    .font(.system(size: 11))
                    .foregroundColor(BrandColors.whiteSwiftUI.opacity(0.58))
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 42)
    }

    private func detectionLabel(for row: AgentSkillsModel.TargetRow) -> String {
        if !row.detected {
            return String(
                localized: "agentSkills.onboarding.notDetected",
                defaultValue: "Not detected — install the agent first, or enable from Settings later."
            )
        }
        if row.allCurrent {
            return String(
                localized: "agentSkills.onboarding.alreadyInstalled",
                defaultValue: "Already current"
            )
        }
        if row.hasOutdated {
            return String(
                localized: "agentSkills.onboarding.updateAvailable",
                defaultValue: "Will update the installed skill"
            )
        }
        if row.anyInstalled {
            return String(
                localized: "agentSkills.onboarding.partialInstalled",
                defaultValue: "Will install the missing skills"
            )
        }
        return String(
            localized: "agentSkills.onboarding.willInstall",
            defaultValue: "Will install the skill"
        )
    }

    private var notDetectedSummary: String {
        let names = ListFormatter.localizedString(byJoining: notDetectedRows.map { $0.target.displayName })
        let format = String(
            localized: "agentSkills.onboarding.notDetectedSummary",
            defaultValue: "Not detected: %@"
        )
        return String(format: format, names)
    }

    private var learnMoreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(BrandColors.ruleSwiftUI.opacity(0.8))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "agentSkills.onboarding.learnMoreTitle", defaultValue: "What gets installed"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.62))

                Text(String(localized: "agentSkills.onboarding.transparency", defaultValue: "Built to be inspectable. The skill is plain text — read it in Finder, or hand it to a model for review. c11 won't touch your agent configuration without your permission."))
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundColor(BrandColors.whiteSwiftUI.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                SecondaryOnboardingButton(
                    title: String(localized: "agentSkills.onboarding.showSkill", defaultValue: "Show Skill Files in Finder"),
                    disabled: model.primarySkillURL == nil,
                    action: { model.revealPrimarySkillInFinder() }
                )
                Spacer(minLength: 0)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            OnboardingActionButton(
                title: String(localized: "agentSkills.onboarding.dontAsk", defaultValue: "Don't ask again"),
                kind: .secondary,
                isSelected: selectedAction == .dontAsk,
                action: dontAskAgain
            )

            OnboardingActionButton(
                title: String(localized: "agentSkills.onboarding.later", defaultValue: "Later"),
                kind: .secondary,
                isSelected: selectedAction == .later,
                action: installLater
            )

            OnboardingActionButton(
                title: primaryActionTitle,
                kind: hasActionNeeded ? .primary : .success,
                isSelected: selectedAction == .install,
                disabled: primaryActionDisabled,
                action: activatePrimaryAction
            )
            .keyboardShortcut(.defaultAction)
        }
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

    private func activatePrimaryAction() {
        if hasActionNeeded {
            guard anySelected else { return }
            applySelection()
        } else if !detectedRows.isEmpty {
            onDismiss()
        }
    }

    private func dontAskAgain() {
        UserDefaults.standard.set(true, forKey: AgentSkillsOnboarding.sheetShownKey)
        onDismiss()
    }

    private func installLater() {
        AgentSkillsOnboarding.markDismissedThisLaunch()
        onDismiss()
    }

    private func activateSelectedAction() {
        switch selectedAction {
        case .dontAsk:
            dontAskAgain()
        case .later:
            installLater()
        case .install:
            activatePrimaryAction()
        }
    }

    private func applyDefaultOptIns(rows: [AgentSkillsModel.TargetRow]) {
        let defaults = AgentSkillsOnboarding.defaultOptIns(for: rows)
        claudeOptIn = defaults[.claude] ?? false
        codexOptIn = defaults[.codex] ?? false
        kimiOptIn = defaults[.kimi] ?? false
        opencodeOptIn = defaults[.opencode] ?? false
    }
}

private enum AgentSkillsOnboardingAction: CaseIterable {
    case dontAsk
    case later
    case install

    static func moved(
        from current: AgentSkillsOnboardingAction,
        direction: ConfirmMoveDirection
    ) -> AgentSkillsOnboardingAction {
        let order = Self.allCases
        guard let index = order.firstIndex(of: current) else { return .install }
        switch direction {
        case .left:
            return order[max(order.startIndex, index - 1)]
        case .right:
            return order[min(order.index(before: order.endIndex), index + 1)]
        case .toggle:
            let next = order.index(after: index)
            return next == order.endIndex ? order[order.startIndex] : order[next]
        }
    }
}

private enum OnboardingActionButtonKind {
    case primary
    case success
    case secondary
}

private struct OnboardingActionButton: View {
    let title: String
    let kind: OnboardingActionButtonKind
    let isSelected: Bool
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: isProminent ? 13 : 12, weight: .semibold))
                .foregroundColor(foregroundColor)
                .lineLimit(1)
                .frame(minWidth: isProminent ? 126 : 108, minHeight: isProminent ? 34 : 28)
                .padding(.horizontal, isProminent ? 10 : 6)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .background(background)
        .overlay(border)
        .selectionBox(isActive: isSelected)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isProminent: Bool {
        kind == .primary || kind == .success
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary, .success:
            return BrandColors.blackSwiftUI
        case .secondary:
            return BrandColors.whiteSwiftUI.opacity(0.9)
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(backgroundColor)
    }

    private var backgroundColor: Color {
        switch kind {
        case .primary:
            return BrandColors.goldSwiftUI
        case .success:
            return Color.green.opacity(0.9)
        case .secondary:
            return BrandColors.whiteSwiftUI.opacity(0.08)
        }
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                borderColor,
                lineWidth: 1
            )
    }

    private var borderColor: Color {
        switch kind {
        case .primary:
            return BrandColors.goldSwiftUI.opacity(0.9)
        case .success:
            return Color.green.opacity(0.95)
        case .secondary:
            return BrandColors.ruleSwiftUI
        }
    }
}

private struct SecondaryOnboardingButton: View {
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(BrandColors.whiteSwiftUI.opacity(0.86))
                .lineLimit(1)
                .frame(minHeight: 28)
                .padding(.horizontal, 12)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(BrandColors.whiteSwiftUI.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(BrandColors.ruleSwiftUI, lineWidth: 1)
        )
        .opacity(disabled ? 0.45 : 1)
    }
}

private struct OnboardingKeyboardMonitor: NSViewRepresentable {
    let onMove: (ConfirmMoveDirection) -> Void
    let onActivate: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: onMove, onActivate: onActivate, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onMove = onMove
        context.coordinator.onActivate = onActivate
        context.coordinator.onCancel = onCancel
        context.coordinator.installMonitor()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var view: NSView?
        var onMove: (ConfirmMoveDirection) -> Void
        var onActivate: () -> Void
        var onCancel: () -> Void
        private var monitor: Any?

        init(
            onMove: @escaping (ConfirmMoveDirection) -> Void,
            onActivate: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onMove = onMove
            self.onActivate = onActivate
            self.onCancel = onCancel
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.shouldHandle(event: event) else { return event }
                return self.handle(event: event) ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func shouldHandle(event: NSEvent) -> Bool {
            guard let window = view?.window, event.window === window, window.isKeyWindow else {
                return false
            }
            return true
        }

        private func handle(event: NSEvent) -> Bool {
            switch event.keyCode {
            case 123, 126:
                onMove(.left)
            case 124, 125:
                onMove(.right)
            case 48:
                onMove(event.modifierFlags.contains(.shift) ? .left : .right)
            case 36, 76, 49:
                onActivate()
            case 53:
                onCancel()
            default:
                return false
            }
            return true
        }
    }
}

private extension View {
    @ViewBuilder
    func selectionBox(isActive: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white, lineWidth: isActive ? 2 : 0)
                .padding(-4)
                .animation(.easeInOut(duration: 0.12), value: isActive)
        )
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

    static func defaultOptIns(for rows: [AgentSkillsModel.TargetRow]) -> [SkillInstallerTarget: Bool] {
        var result = Dictionary(uniqueKeysWithValues: SkillInstallerTarget.allCases.map { ($0, false) })
        for row in rows {
            result[row.target] = row.detected
        }
        return result
    }

    static func shouldOffer(for rows: [AgentSkillsModel.TargetRow]) -> Bool {
        rows.contains { $0.detected && $0.needsInstallOrUpdate }
    }

    static func shouldOffer(for statuses: [SkillInstallerPackageStatus]) -> Bool {
        !statuses.isEmpty && statuses.contains { $0.state == .notInstalled || $0.state == .installedOutdated }
    }

    /// Should the onboarding sheet be offered on this launch? True iff at
    /// least one detected agent environment is missing the current bundled
    /// skill set, and the user hasn't already dismissed the sheet.
    @MainActor static func shouldPresent(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        if defaults.bool(forKey: sheetShownKey) { return false }
        if _dismissedThisLaunch { return false }
        guard let source = SkillInstaller.defaultSourceURL(executableURL: Bundle.main.executableURL) else { return false }
        for target in SkillInstallerTarget.allCases where target.isDetected(home: home, fileManager: fileManager) {
            guard let statuses = try? SkillInstaller.status(
                for: target,
                home: home,
                sourceDir: source,
                fileManager: fileManager
            ) else {
                continue
            }
            if shouldOffer(for: statuses) { return true }
        }
        return false
    }
}
