import SwiftUI
import AppKit

// MARK: - First-run TCC primer sheet

/// Shown before the first shell spawns, giving the user the choice to
/// pre-grant Full Disk Access (recommended by iTerm2, Warp, and Ghostty)
/// or proceed and respond to per-folder TCC prompts individually.
struct TCCPrimerSheet: View {
    let onGrantFDA: () -> Void
    let onContinueWithout: () -> Void
    let onDismiss: () -> Void

    init(
        onGrantFDA: @escaping () -> Void = {},
        onContinueWithout: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {}
    ) {
        self.onGrantFDA = onGrantFDA
        self.onContinueWithout = onContinueWithout
        self.onDismiss = onDismiss
    }

    @State private var selectedAction: TCCPrimerAction = .grantFDA

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            bodyCopy
            learnMoreSection
            footer
        }
        .padding(24)
        .frame(width: 540)
        .background(OnboardingKeyboardMonitor(
            onMove: { direction in
                selectedAction = TCCPrimerAction.moved(
                    from: selectedAction,
                    direction: direction
                )
            },
            onActivate: { activateSelectedAction() },
            onCancel: { onContinueWithout() }
        ))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(
                localized: "tccPrimer.title",
                defaultValue: "Before your first shell opens."
            ))
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(BrandColors.whiteSwiftUI)

            Text(String(
                localized: "tccPrimer.body.why",
                defaultValue: "c11 is a host for your shells and agents. The moment a process you started inside c11 touches a protected place — Downloads, Documents, Desktop, iCloud Drive, Music, Photos, Contacts, an external drive — macOS pauses and asks you whether that's OK. That's how TCC works: each folder is its own consent, and only you can grant it."
            ))
            .font(.system(size: 12, weight: .regular))
            .lineSpacing(2)
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.76))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bodyCopy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "tccPrimer.body.fullDisk",
                defaultValue: "Grant Full Disk Access once in System Settings → Privacy & Security and you won't see individual dialogs at all. This is what iTerm2, Warp, and Ghostty recommend for engineers running many agents. You can revoke it any time."
            ))
            .font(.system(size: 12, weight: .regular))
            .lineSpacing(2)
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.76))
            .fixedSize(horizontal: false, vertical: true)

            Text(String(
                localized: "tccPrimer.body.whoAsks",
                defaultValue: "The dialog will say \"c11 wants to access…\" because macOS attributes the request to the parent app. The actual requester is whatever you — or an agent — just ran."
            ))
            .font(.system(size: 12, weight: .regular))
            .lineSpacing(2)
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.76))
            .fixedSize(horizontal: false, vertical: true)

            Text(sayNoAttributed)
                .font(.system(size: 12, weight: .regular))
                .lineSpacing(2)
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sayNoAttributed: AttributedString {
        let bold = String(
            localized: "tccPrimer.body.sayNo.lead",
            defaultValue: "Feel free to say no to any of them."
        )
        let tail = String(
            localized: "tccPrimer.body.sayNo.tail",
            defaultValue: " c11 itself doesn't scan your files, and nothing is forwarded to Stage 11. If you deny a folder, the command that tripped it will just fail, and you can grant it later in System Settings."
        )
        var leadStr = AttributedString(bold)
        leadStr.font = .system(size: 12, weight: .semibold)
        var tailStr = AttributedString(tail)
        tailStr.font = .system(size: 12, weight: .regular)
        return leadStr + tailStr
    }

    private var learnMoreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(BrandColors.ruleSwiftUI.opacity(0.7))
                .frame(height: 1)
            Text(String(
                localized: "tccPrimer.learnMore.title",
                defaultValue: "What triggers each prompt"
            ))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.62))

            Text(String(
                localized: "tccPrimer.learnMore.body",
                defaultValue: "Each prompt is tied to a specific macOS permission: folder prompts (Downloads, Documents, Desktop) fire when a child process reads or writes there; the iCloud Drive prompt fires when anything touches a File Provider domain; Music and Photos fire when a process reads the media libraries; Local Network fires on Bonjour or LAN HTTP. The copy inside each dialog comes from Info.plist and is c11-authored."
            ))
            .font(.system(size: 11, weight: .regular))
            .lineSpacing(2)
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.66))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            OnboardingActionButton(
                title: String(
                    localized: "tccPrimer.button.continueWithout",
                    defaultValue: "Continue without it"
                ),
                kind: .secondary,
                isSelected: selectedAction == .continueWithout,
                action: onContinueWithout
            )

            OnboardingActionButton(
                title: String(
                    localized: "tccPrimer.button.grantFDA",
                    defaultValue: "Grant Full Disk Access"
                ),
                kind: .primary,
                isSelected: selectedAction == .grantFDA,
                action: onGrantFDA
            )
        }
    }

    private func activateSelectedAction() {
        switch selectedAction {
        case .grantFDA:
            onGrantFDA()
        case .continueWithout:
            onContinueWithout()
        }
    }
}

private enum TCCPrimerAction: CaseIterable {
    case continueWithout
    case grantFDA

    static func moved(
        from current: TCCPrimerAction,
        direction: ConfirmMoveDirection
    ) -> TCCPrimerAction {
        let order = Self.allCases
        guard let index = order.firstIndex(of: current) else { return .grantFDA }
        switch direction {
        case .left:
            return order[max(order.startIndex, index - 1)]
        case .right:
            return order[min(order.endIndex - 1, index + 1)]
        case .toggle:
            let next = (index + 1) % order.count
            return order[next]
        }
    }
}

// MARK: - Presentation gate

enum TCCPrimer {
    /// Persistent "primer shown" flag. Set by the Continue/Grant buttons and
    /// also by the one-shot migration that marks existing welcome-completed
    /// users as already-seen on first launch of a build that ships this sheet.
    static let shownKey = "cmuxTCCPrimerShown"

    /// In-memory flag scoped to the current launch. Set when the user
    /// dismisses the sheet via the red close button (which never runs
    /// onContinueWithout). Prevents a chained welcome workspace or re-entry
    /// path from popping the sheet again in the same run.
    @MainActor private static var _dismissedThisLaunch: Bool = false

    @MainActor static func markDismissedThisLaunch() {
        _dismissedThisLaunch = true
    }

    @MainActor static var dismissedThisLaunch: Bool {
        _dismissedThisLaunch
    }

    @MainActor static func shouldPresent(
        defaults: UserDefaults = .standard
    ) -> Bool {
        if defaults.bool(forKey: shownKey) { return false }
        if _dismissedThisLaunch { return false }
        return true
    }

    /// One-shot migration for pre-existing users: anyone who has already
    /// seen the welcome workspace is assumed to have already navigated the
    /// permission dialogs the old-fashioned way, and shouldn't be surprised
    /// by a retroactive primer. Safe to call on every launch — runs once.
    @MainActor static func migrateExistingUserIfNeeded(
        defaults: UserDefaults = .standard
    ) {
        guard defaults.object(forKey: shownKey) == nil else { return }
        if defaults.bool(forKey: WelcomeSettings.shownKey) {
            defaults.set(true, forKey: shownKey)
        }
    }

    @MainActor static func openFullDiskAccessPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
