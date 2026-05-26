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
            // Any package this call touched is now `.installedCurrent`;
            // a stale dismissal entry against an older bundled hash would
            // shadow future drift on the next release. Clear it.
            for name in result.installed + result.refreshed {
                AgentSkillsOnboarding.clearDismissal(for: target, skillName: name)
            }
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
        // Open the skills folder itself so the operator sees the SKILL.md
        // files. activateFileViewerSelecting reveals the folder from its
        // parent — one level too high to be useful here.
        NSWorkspace.shared.open(url)
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
    @State private var grokOptIn: Bool = false
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
                selectedAction = AgentSkillsOnboardingAction.moved(
                    from: selectedAction,
                    direction: direction,
                    within: visibleActions
                )
            },
            onActivate: { activateSelectedAction() },
            onCancel: { hasActionNeeded ? installLater() : onDismiss() }
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
        initializedDefaultOptIns && (claudeOptIn || codexOptIn || grokOptIn || kimiOptIn || opencodeOptIn)
    }

    private var hasActionNeeded: Bool {
        detectedRows.contains { $0.needsInstallOrUpdate }
    }

    private var anyRowInstalled: Bool {
        detectedRows.contains { $0.anyInstalled }
    }

    private var primaryActionDisabled: Bool {
        detectedRows.isEmpty || (hasActionNeeded && !anySelected)
    }

    private var primaryActionTitle: String {
        if !detectedRows.isEmpty && !hasActionNeeded {
            // Celebratory state: everything is current. Primary action is
            // a friendly "Done" — see C11-111 amendment #2.
            return String(localized: "agentSkills.onboarding.done", defaultValue: "Done")
        }
        // Default is "Update all" — checked-by-default rows mean a single
        // click resolves every offered row in one shot. The label flips to
        // "Update selected" only if the operator un-checks at least one row.
        if !allOfferedSelected {
            return String(localized: "agentSkills.onboarding.updateSelected", defaultValue: "Update selected")
        }
        return String(localized: "agentSkills.onboarding.updateAll", defaultValue: "Update all")
    }

    /// True when every (target, skill) row that needs action is currently
    /// covered by the operator's per-target opt-in toggles. Lets the
    /// primary button distinguish "single-click resolves everything"
    /// (`Update all`) from "operator has narrowed the set" (`Update
    /// selected`).
    private var allOfferedSelected: Bool {
        for row in detectedRows where row.needsInstallOrUpdate {
            if !optInBinding(for: row.target).wrappedValue { return false }
        }
        return true
    }

    private var visibleActions: [AgentSkillsOnboardingAction] {
        hasActionNeeded ? AgentSkillsOnboardingAction.allCases : [.install]
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
            Text(headerTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)

            Text(headerBody)
                .font(.system(size: 12, weight: .regular))
                .lineSpacing(2)
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerTitle: String {
        // Celebratory branch (manual invocation, nothing to do).
        if !detectedRows.isEmpty && !hasActionNeeded {
            return String(
                localized: "agentSkills.onboarding.title.celebratory",
                defaultValue: "Your agent is current with c11."
            )
        }
        if anyRowInstalled {
            return String(
                localized: "agentSkills.onboarding.title.known",
                defaultValue: "Your agent already knows c11."
            )
        }
        return String(
            localized: "agentSkills.onboarding.title",
            defaultValue: "Your agent doesn't know c11 yet."
        )
    }

    private var headerBody: String {
        if !detectedRows.isEmpty && !hasActionNeeded {
            return String(
                localized: "agentSkills.onboarding.body.celebratory",
                defaultValue: "Every detected agent has the latest c11 skill set."
            )
        }
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

    private func onboardingRow(row: AgentSkillsModel.TargetRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: optInBinding(for: row.target)) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!row.detected || !row.needsInstallOrUpdate)

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

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "agentSkills.onboarding.learnMoreTitle", defaultValue: "What gets installed"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.62))

                Text(String(localized: "agentSkills.onboarding.transparency", defaultValue: "Built to be inspectable. The skill is plain text — open it in Finder to read exactly what your agent will learn, or install it yourself in any agent that supports the SKILL.md standard."))
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundColor(BrandColors.whiteSwiftUI.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(localized: "agentSkills.onboarding.permission", defaultValue: "c11 won't touch your agent configuration without your permission."))
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
                // Celebratory branch: offer "Refresh all" so the operator
                // can force-rewrite all installed skills if they suspect
                // tampering even though hashes happen to match.
                if !detectedRows.isEmpty && !hasActionNeeded {
                    SecondaryOnboardingButton(
                        title: String(localized: "agentSkills.onboarding.refreshAll", defaultValue: "Refresh all"),
                        action: refreshAll
                    )
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            if hasActionNeeded {
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
            }

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
        case .grok: return $grokOptIn
        case .kimi: return $kimiOptIn
        case .opencode: return $opencodeOptIn
        }
    }

    private func applySelection() {
        let selections: [(SkillInstallerTarget, Bool)] = [
            (.claude, claudeOptIn),
            (.codex, codexOptIn),
            (.grok, grokOptIn),
            (.kimi, kimiOptIn),
            (.opencode, opencodeOptIn),
        ]
        var selectedKeys: Set<String> = []
        for (target, _) in selections.filter({ $0.1 }) {
            guard let row = model.rows.first(where: { $0.target == target }), row.detected else { continue }
            for status in row.packages where AgentSkillsOnboarding.shouldRowOffer(status) {
                selectedKeys.insert(AgentSkillsOnboarding.dismissalKey(for: target, skillName: status.package.name))
            }
        }
        let offered = model.rows.filter(\.detected).flatMap(\.packages)
        AgentSkillsOnboarding.recordDismissalsForUncheckedRows(
            offered: offered,
            selectedKeys: selectedKeys
        )
        for (target, _) in selections.filter({ $0.1 }) {
            guard let row = model.rows.first(where: { $0.target == target }), row.detected else { continue }
            model.install(target: target, force: true)
        }
        onDismiss()
    }

    private func activatePrimaryAction() {
        if hasActionNeeded {
            guard anySelected else { return }
            applySelection()
        } else if !detectedRows.isEmpty {
            // Celebratory state: primary action is "Done", which just
            // closes the sheet.
            onDismiss()
        }
    }

    /// Force-refresh every (target, skill) regardless of state. Backs the
    /// celebratory state's "Refresh all" affordance: lets the operator
    /// rewrite local skill files without leaving the sheet, useful when
    /// they suspect tampering even though hashes happen to match.
    private func refreshAll() {
        for row in detectedRows {
            model.install(target: row.target, force: true)
        }
    }

    private func dontAskAgain() {
        UserDefaults.standard.set(true, forKey: AgentSkillsOnboarding.dontAskAgainKey)
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
        grokOptIn = defaults[.grok] ?? false
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
        direction: ConfirmMoveDirection,
        within options: [AgentSkillsOnboardingAction] = Self.allCases
    ) -> AgentSkillsOnboardingAction {
        let order = options
        guard !order.isEmpty else { return current }
        let index = order.firstIndex(of: current) ?? order.startIndex
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

enum OnboardingActionButtonKind {
    case primary
    case success
    case secondary
}

struct OnboardingActionButton: View {
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

struct OnboardingKeyboardMonitor: NSViewRepresentable {
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
    /// Legacy "Don't ask again" flag used by c11 ≤ v0.49.x. Kept as a
    /// migration breadcrumb only — see `migrateLegacyDismissalsIfNeeded`.
    /// Never read by `shouldPresent` directly; the new `dontAskAgainKey`
    /// supersedes it.
    static let legacyOnboardingShownKey = "cmuxAgentSkillsOnboardingShown"

    /// Persistent "Don't ask again" flag. Set only by the explicit button in
    /// the onboarding sheet. Honored regardless of skill content changes —
    /// the operator's explicit opt-out wins over drift detection. Cleared
    /// by Help → "Re-enable agent skills install prompts."
    static let dontAskAgainKey = "c11SkillDontAskAgain"

    /// Per-(target, skill) dismissed-against-hash store. Key shape
    /// `"<target.rawValue>.<skillName>"`, value is the bundled
    /// `sourceContentHash` at dismissal time. A row whose current bundled
    /// hash matches its stored dismissal hash is suppressed; when the
    /// bundled hash changes (new c11 release with revised content) the row
    /// re-surfaces. Written only by the "Update selected" branch; never by
    /// "Maybe later" or window close (those use the in-memory
    /// `_dismissedThisLaunch` flag).
    static let dismissalsKey = "c11SkillDismissals"

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

    /// Test-only reset hook for the per-launch dismissal flag. Production
    /// code never clears the flag mid-launch — that's the entire point of
    /// "Maybe later" surviving until the next process start. Tests need to
    /// reset it between cases to keep the process-wide static from
    /// polluting unrelated tests. Don't call this from app code.
    @MainActor static func _resetDismissedThisLaunchForTests() {
        _dismissedThisLaunch = false
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
        !statuses.isEmpty && statuses.contains { shouldRowOffer($0) }
    }

    /// True when this individual (target, skill) status would prompt the
    /// operator. The dismissal store is consulted by the caller — this
    /// function only classifies the on-disk state.
    static func shouldRowOffer(_ status: SkillInstallerPackageStatus) -> Bool {
        switch status.state {
        case .notInstalled, .installedOutdated, .installedNoManifest, .schemaMismatch:
            return true
        case .installedCurrent:
            return false
        }
    }

    static func dismissalKey(for target: SkillInstallerTarget, skillName: String) -> String {
        "\(target.rawValue).\(skillName)"
    }

    /// Read the persisted dismissal dict. Tolerant of missing key or
    /// malformed values — returns an empty dict rather than crashing, so a
    /// corrupted defaults entry can't lock the operator out of the sheet.
    static func loadDismissals(defaults: UserDefaults = .standard) -> [String: String] {
        guard let raw = defaults.dictionary(forKey: dismissalsKey) else { return [:] }
        var clean: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String { clean[k] = s }
        }
        return clean
    }

    static func saveDismissals(_ dict: [String: String], defaults: UserDefaults = .standard) {
        if dict.isEmpty {
            defaults.removeObject(forKey: dismissalsKey)
        } else {
            defaults.set(dict, forKey: dismissalsKey)
        }
    }

    /// Record persistent dismissals for every (target, skill) the operator
    /// left unchecked when invoking "Update selected." Captures the current
    /// bundled hash so a future c11 release with revised content
    /// re-surfaces the row. Skips `.installedCurrent` (no actionable state)
    /// and any row that was checked (it'll be installed instead).
    ///
    /// The unchecked-row set is computed by intersecting the offered rows
    /// with the operator's selection state: a row is "unchecked" if its
    /// `(target, skill)` is in `offeredRows` but absent from `selectedKeys`.
    static func recordDismissalsForUncheckedRows(
        offered: [SkillInstallerPackageStatus],
        selectedKeys: Set<String>,
        defaults: UserDefaults = .standard
    ) {
        var dict = loadDismissals(defaults: defaults)
        for status in offered where shouldRowOffer(status) {
            let key = dismissalKey(for: status.target, skillName: status.package.name)
            if selectedKeys.contains(key) { continue }
            dict[key] = status.sourceContentHash
        }
        saveDismissals(dict, defaults: defaults)
    }

    /// Drop a single (target, skill) entry. Called after a successful
    /// install of that pair so the next content change isn't shadowed by an
    /// outdated dismissal hash.
    static func clearDismissal(
        for target: SkillInstallerTarget,
        skillName: String,
        defaults: UserDefaults = .standard
    ) {
        var dict = loadDismissals(defaults: defaults)
        guard dict.removeValue(forKey: dismissalKey(for: target, skillName: skillName)) != nil else { return }
        saveDismissals(dict, defaults: defaults)
    }

    /// One-shot migration of the legacy `cmuxAgentSkillsOnboardingShown`
    /// flag into the new dismissal store. Runs only when no `c11SkillDismissals`
    /// dict exists yet (so it can't clobber operator decisions made on this
    /// version). For each (target, skill) pair currently `.installedCurrent`,
    /// records a dismissal entry against the present bundled hash. Outdated /
    /// not-installed pairs are intentionally NOT recorded — they need to
    /// surface so the operator sees the revised content (the bug this whole
    /// ticket exists to fix). The legacy flag is *not* mapped onto
    /// `dontAskAgainKey`: pre-v0.50.0 the flag fired on first successful
    /// install too, not just explicit opt-out, so honoring it as a global
    /// silence would over-suppress.
    static func migrateLegacyDismissalsIfNeeded(
        home: URL,
        sourceDir: URL,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.dictionary(forKey: dismissalsKey) == nil else { return }
        guard defaults.bool(forKey: legacyOnboardingShownKey) else { return }

        var dict: [String: String] = [:]
        for target in SkillInstallerTarget.allCases where target.isDetected(home: home, fileManager: fileManager) {
            guard let statuses = try? SkillInstaller.status(
                for: target,
                home: home,
                sourceDir: sourceDir,
                fileManager: fileManager
            ) else { continue }
            for status in statuses where status.state == .installedCurrent {
                dict[dismissalKey(for: target, skillName: status.package.name)] = status.sourceContentHash
            }
        }
        // Always persist (even an empty dict) so the migration runs exactly
        // once. Subsequent calls find a present key and short-circuit.
        defaults.set(dict, forKey: dismissalsKey)
    }

    /// Should the onboarding sheet be offered on this launch?
    ///
    /// Order of suppression checks (cheapest first):
    /// 1. Explicit `dontAskAgain` opt-out wins over everything.
    /// 2. In-memory `_dismissedThisLaunch` covers the "Later" / window-close
    ///    paths for the current run.
    /// 3. For each detected target × bundled skill that would otherwise
    ///    offer, the persistent dismissal entry (if any) must match the
    ///    current bundled hash. A matching entry suppresses that row; a
    ///    mismatched entry (content drifted since dismissal) re-surfaces
    ///    it. If any row remains un-suppressed after these checks, the
    ///    sheet is offered.
    @MainActor static func shouldPresent(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        sourceDir: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        if defaults.bool(forKey: dontAskAgainKey) { return false }
        if _dismissedThisLaunch { return false }
        let resolvedSource: URL
        if let sourceDir {
            resolvedSource = sourceDir
        } else {
            guard let s = SkillInstaller.defaultSourceURL(executableURL: Bundle.main.executableURL) else { return false }
            resolvedSource = s
        }
        let source = resolvedSource
        migrateLegacyDismissalsIfNeeded(home: home, sourceDir: source, fileManager: fileManager, defaults: defaults)
        let dismissals = loadDismissals(defaults: defaults)
        for target in SkillInstallerTarget.allCases where target.isDetected(home: home, fileManager: fileManager) {
            guard let statuses = try? SkillInstaller.status(
                for: target,
                home: home,
                sourceDir: source,
                fileManager: fileManager
            ) else {
                continue
            }
            for status in statuses where shouldRowOffer(status) {
                let key = dismissalKey(for: target, skillName: status.package.name)
                if let stored = dismissals[key], stored == status.sourceContentHash { continue }
                return true
            }
        }
        return false
    }

    /// True when the operator has either explicitly opted out via
    /// "Don't ask again" or has any dismissed entries left over. Drives the
    /// Help → "Re-enable agent skills install prompts" visibility gate so
    /// the menu item only appears when there's something to clear.
    static func hasSilencedState(defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: dontAskAgainKey) { return true }
        if !loadDismissals(defaults: defaults).isEmpty { return true }
        return false
    }

    /// Clear both the global "Don't ask again" flag and every per-(target, skill)
    /// dismissal entry. Called by the Help → "Re-enable agent skills install
    /// prompts" action.
    static func clearAllSilencing(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: dontAskAgainKey)
        defaults.removeObject(forKey: dismissalsKey)
    }
}
