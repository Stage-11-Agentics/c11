import AppKit
import SwiftUI
import Darwin
import Bonsplit
import UniformTypeIdentifiers

enum WorkspaceTitlebarSettings {
    static let showTitlebarKey = "workspaceTitlebarVisible"
    static let defaultShowTitlebar = true

    static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showTitlebarKey) == nil {
            return defaultShowTitlebar
        }
        return defaults.bool(forKey: showTitlebarKey)
    }
}

enum WorkspacePresentationModeSettings {
    static let modeKey = "workspacePresentationMode"

    enum Mode: String {
        case standard
        case minimal
    }

    static let defaultMode: Mode = .standard

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue ?? "") ?? defaultMode
    }

    static func mode(defaults: UserDefaults = .standard) -> Mode {
        mode(for: defaults.string(forKey: modeKey))
    }

    static func isMinimal(defaults: UserDefaults = .standard) -> Bool {
        mode(defaults: defaults) == .minimal
    }

    static func ignoresTopSafeArea(for mode: Mode) -> Bool {
        mode == .minimal
    }
}

enum WorkspaceButtonFadeSettings {
    static let modeKey = "workspaceButtonsFadeMode"
    static let legacyTitlebarControlsVisibilityModeKey = "titlebarControlsVisibilityMode"
    static let legacyPaneTabBarControlsVisibilityModeKey = "paneTabBarControlsVisibilityMode"

    enum Mode: String {
        case enabled
        case disabled
    }

    static let defaultMode: Mode = .disabled

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue ?? "") ?? defaultMode
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        mode(for: defaults.string(forKey: modeKey)) == .enabled
    }

    static func initializeStoredModeIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: modeKey) == nil else { return }

        if let migratedMode = migratedLegacyMode(defaults: defaults) {
            defaults.set(migratedMode.rawValue, forKey: modeKey)
            return
        }

        let initialMode: Mode = WorkspaceTitlebarSettings.isVisible(defaults: defaults) ? .disabled : .enabled
        defaults.set(initialMode.rawValue, forKey: modeKey)
    }

    private static func migratedLegacyMode(defaults: UserDefaults) -> Mode? {
        let legacyValues = [
            defaults.string(forKey: legacyTitlebarControlsVisibilityModeKey),
            defaults.string(forKey: legacyPaneTabBarControlsVisibilityModeKey),
        ]

        if legacyValues.contains(where: { $0 == "onHover" || $0 == "hover" || $0 == "enabled" }) {
            return .enabled
        }
        if legacyValues.contains(where: { $0 == "always" || $0 == "disabled" }) {
            return .disabled
        }
        return nil
    }
}

enum UITestLaunchManifest {
    static let argumentName = "-cmuxUITestLaunchManifest"

    struct Payload: Decodable {
        let environment: [String: String]
    }

    static func applyIfPresent(
        arguments: [String] = CommandLine.arguments,
        loadData: (String) -> Data? = { path in
            try? Data(contentsOf: URL(fileURLWithPath: path))
        },
        applyEnvironment: (String, String) -> Void = { key, value in
            setenv(key, value, 1)
        }
    ) {
        guard let path = manifestPath(from: arguments),
              let data = loadData(path),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return
        }

        for (key, value) in payload.environment {
            applyEnvironment(key, value)
        }
    }

    static func manifestPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argumentName) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }

        let rawPath = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return rawPath.isEmpty ? nil : rawPath
    }
}

@main
struct cmuxApp: App {
    // Declared first: stored properties initialize in order, so this runs before
    // any initializer below reads a setting or a file (C11H-266).
    private let startupGate: Void = cmuxApp.prepareLaunchEnvironmentAndMigrate()
    @ObservedObject private var focusHistory = FocusHistoryStore.shared
    @StateObject private var workspaceManager: WorkspaceManager
    @StateObject private var notificationStore = TerminalNotificationStore.shared
    @StateObject private var sidebarState = SidebarState()
    @StateObject private var sidebarSelectionState = SidebarSelectionState()
    // c11 (C11H-197): the primary window keeps its UUID across launches.
    private let primaryWindowId = PrimaryWindowIdentity.launchWindowId()
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyle = TitlebarControlsStyle.classic.rawValue
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(KeyboardShortcutSettings.Action.toggleSidebar.defaultsKey) private var toggleSidebarShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.newWorkspace.defaultsKey) private var newWorkspaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.newWindow.defaultsKey) private var newWindowShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.showNotifications.defaultsKey) private var showNotificationsShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.jumpToUnread.defaultsKey) private var jumpToUnreadShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.nextSurface.defaultsKey) private var nextSurfaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.prevSurface.defaultsKey) private var prevSurfaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.nextSidebarWorkspace.defaultsKey) private var nextWorkspaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.prevSidebarWorkspace.defaultsKey) private var prevWorkspaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.focusHistoryBack.defaultsKey) private var focusHistoryBackShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.focusHistoryForward.defaultsKey) private var focusHistoryForwardShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.splitRight.defaultsKey) private var splitRightShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.splitDown.defaultsKey) private var splitDownShortcutData = Data()
    @AppStorage(BrowserToolbarAccessorySpacingDebugSettings.key) private var browserToolbarAccessorySpacingRaw = BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
    @AppStorage(ThemeAppStorage.Keys.engineDisabledRuntime, store: ThemeAppStorage.defaults)
    private var themeEngineDisabledRuntime = false
    @AppStorage(ThemeAppStorage.Keys.m1bSurfaceTitleBarMigrated, store: ThemeAppStorage.defaults)
    private var m1bSurfaceTitleBarMigrated = false
    @AppStorage(ThemeAppStorage.Keys.m1bBrowserChromeMigrated, store: ThemeAppStorage.defaults)
    private var m1bBrowserChromeMigrated = false
    @AppStorage(ThemeAppStorage.Keys.m1bMarkdownChromeMigrated, store: ThemeAppStorage.defaults)
    private var m1bMarkdownChromeMigrated = false
    @AppStorage(ThemeAppStorage.Keys.m1bBonsplitAppearanceMigrated, store: ThemeAppStorage.defaults)
    private var m1bBonsplitAppearanceMigrated = false
    @AppStorage(ThemeAppStorage.Keys.m1bSidebarTabItemMigrated, store: ThemeAppStorage.defaults)
    private var m1bSidebarTabItemMigrated = false
    @AppStorage(ThemeAppStorage.Keys.m1bCustomTitlebarMigrated, store: ThemeAppStorage.defaults)
    private var m1bCustomTitlebarMigrated = false
    @AppStorage(ThemeAppStorage.Keys.m1bWorkspaceContentViewContextMigrated, store: ThemeAppStorage.defaults)
    private var m1bWorkspaceContentViewContextMigrated = false
    @AppStorage(KeyboardShortcutSettings.Action.toggleBrowserDeveloperTools.defaultsKey)
    private var toggleBrowserDeveloperToolsShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.showBrowserJavaScriptConsole.defaultsKey)
    private var showBrowserJavaScriptConsoleShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.splitBrowserRight.defaultsKey) private var splitBrowserRightShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.splitBrowserDown.defaultsKey) private var splitBrowserDownShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.renameWorkspace.defaultsKey) private var renameWorkspaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.openFolder.defaultsKey) private var openFolderShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.closeWorkspace.defaultsKey) private var closeWorkspaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.focusLeft.defaultsKey) private var focusLeftShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.focusRight.defaultsKey) private var focusRightShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.focusUp.defaultsKey) private var focusUpShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.focusDown.defaultsKey) private var focusDownShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.toggleSplitZoom.defaultsKey) private var toggleSplitZoomShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.newSurface.defaultsKey) private var newSurfaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.newAgent.defaultsKey) private var newAgentShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.openBrowser.defaultsKey) private var openBrowserShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.renamePanel.defaultsKey) private var renamePanelShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.globalFontIncrease.defaultsKey) private var globalFontIncreaseShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.globalFontDecrease.defaultsKey) private var globalFontDecreaseShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.globalFontReset.defaultsKey) private var globalFontResetShortcutData = Data()
    @AppStorage(ChromeScaleSettings.presetKey) private var chromeScalePresetRaw = ChromeScaleSettings.defaultPreset.rawValue
    @AppStorage(ChromeScaleSettings.customMultiplierKey) private var chromeScaleCustomMultiplier: Double = Double(ChromeScaleSettings.defaultCustomMultiplier)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var browserToolbarAccessorySpacing: Int {
        BrowserToolbarAccessorySpacingDebugSettings.resolved(browserToolbarAccessorySpacingRaw)
    }

    /// Runs once, from the first stored property, before every other initializer.
    private static func prepareLaunchEnvironmentAndMigrate() {
        // First, so every launch-time read below sees MUX11_* fallbacks as C11_*.
        applyC11EnvAliasOverrides()
        // c11h: after the alias fill, so an inherited MUX11_* identity name
        // becomes C11_* and is scrubbed with the rest. C11H-34: before anything
        // reads, mirrors or hands on the environment. A launch from a c11
        // terminal carries that terminal's identity and the launching agent's
        // session markers.
        let scrubbed = HCLaunchEnvironmentScrub.scrubProcessEnvironment()
        // C11H-415: and from the exec-time copy hc reads. hc ends a closed
        // panel's leftovers by the `HC_SCOPE` token in each process's recorded
        // environment, so an app `open -a` started from a c11 terminal carried
        // that terminal's token and was hung up when the panel closed.
        HCLaunchEnvironmentScrub.blankOwnExecEnvironment(alsoNames: scrubbed)
        UITestLaunchManifest.applyIfPresent()

        if SocketControlSettings.shouldBlockUntaggedDebugLaunch() {
            Self.terminateForMissingLaunchTag()
        }

        // A duplicate must leave before creating the launch workspace or
        // touching the shared session, shutdown sentinel or control socket.
        AppDelegate.yieldToRunningInstanceIfNeeded()

        // c11 2.0 (C11H-266): carry c11h's or c11 1.x's state over, in the one  // c11-2.0:legacy
        // instance that stays. Returns only when normal startup may go ahead;
        // otherwise the migration gate takes over and this process exits.
        C11MigrationLaunch.bootstrap()
    }

    init() {
        // c11h: C11H-203: this install's id may write UserDefaults the first
        // time it is read; read it here, on main, before an hc session
        // actor stamps it on a new terminal.
        _ = HCOwnerLabels.appInstallID

        Self.configureGhosttyEnvironment()

        // Apply saved language preference before any UI loads
        LanguageSettings.apply(LanguageSettings.languageAtLaunch)

        // Themes are the single source of truth for appearance. Force dark so the
        // system light/dark setting doesn't recolor NSColor-based chrome under us.
        UserDefaults.standard.set(AppearanceMode.dark.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        Self.applyAppearance(.dark)
        // Carry the old `tabLayoutMode` forward before the Settings picker or any workspace reads it.
        PanelLayoutSettings.migrateLegacyKeys(defaults: .standard)
        // The initial WorkspaceManager immediately creates a workspace and its
        // terminal. Start recording before those lifecycle edges can be emitted.
        mirrorC11CmuxEnv()
        #if DEBUG
        // Before the first dlog: a per-user debug log (or /dev/null), never /tmp.
        C11UserRuntime.secureDebugLogEnvironment(
            defaultName: (SocketControlSettings.taggedDebugSocketStem(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                environment: ProcessInfo.processInfo.environment
            ) ?? "c11-debug") + ".log"
        )
        #endif
        EventEmitter.shared.start()
        // Reading an uninstalled StateObject re-evaluates its autoclosure.
        // Share one launch instance with SwiftUI and the early delegate wiring.
        HCBackendComposition.shared.activateOrUnavailable(
            home: FileManager.default.homeDirectoryForCurrentUser,
            tag: SocketControlSettings.hcLaunchTag(), inherited: ProcessInfo.processInfo.environment)
        // C11H-260: the workspace c11 opens at launch is c11's own. A restore
        // replaces it and its lineage; a fresh start keeps it.
        let launchWorkspaceManager = PanelLineage.shared.withOrigin(.app(PanelOriginRequest.AppReason.launch)) {
            WorkspaceManager()
        }
        _workspaceManager = StateObject(wrappedValue: launchWorkspaceManager)
        // Migrate legacy and old-format socket mode values to the new enum.
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: SocketControlSettings.appStorageKey) {
            let migrated = SocketControlSettings.migrateMode(stored)
            if migrated.rawValue != stored {
                defaults.set(migrated.rawValue, forKey: SocketControlSettings.appStorageKey)
            }
        } else if let legacy = defaults.object(forKey: SocketControlSettings.legacyEnabledKey) as? Bool {
            defaults.set(legacy ? SocketControlMode.c11Only.rawValue : SocketControlMode.off.rawValue,
                         forKey: SocketControlSettings.appStorageKey)
        }
        // Skip keychain migration for DEV/staging builds. Each tagged build gets a
        // unique bundle ID with its own UserDefaults domain, so migration would run
        // on every launch and trigger a macOS keychain access prompt (the legacy
        // keychain item was created by a differently-signed app).
        let bundleID = Bundle.main.bundleIdentifier
        if !SocketControlSettings.isDebugLikeBundleIdentifier(bundleID)
            && !SocketControlSettings.isStagingBundleIdentifier(bundleID) {
            SocketControlPasswordStore.migrateLegacyKeychainPasswordIfNeeded(defaults: defaults)
        }
        migrateSidebarAppearanceDefaultsIfNeeded(defaults: defaults)

        // UI tests depend on AppDelegate wiring happening even if SwiftUI view appearance
        // callbacks (e.g. `.onAppear`) are delayed or skipped.
        appDelegate.configure(workspaceManager: launchWorkspaceManager, notificationStore: notificationStore, sidebarState: sidebarState)
    }

    private static func terminateForMissingLaunchTag() -> Never {
        let message = "error: refusing to launch untagged c11 DEV; start with ./scripts/reload.sh --tag <name> (or set C11_TAG for test harnesses)"
        fputs("\(message)\n", stderr)
        fflush(stderr)
        NSLog("%@", message)
        Darwin.exit(64)
    }

    private static func configureGhosttyEnvironment() {
        let fileManager = FileManager.default
        let ghosttyAppResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        let bundledGhosttyURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty")
        var resolvedResourcesDir: String?

        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            if let bundledGhosttyURL,
               fileManager.fileExists(atPath: bundledGhosttyURL.path),
               fileManager.fileExists(atPath: bundledGhosttyURL.appendingPathComponent("themes").path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            } else if fileManager.fileExists(atPath: ghosttyAppResources) {
                resolvedResourcesDir = ghosttyAppResources
            } else if let bundledGhosttyURL, fileManager.fileExists(atPath: bundledGhosttyURL.path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            }

            if let resolvedResourcesDir {
                setenv("GHOSTTY_RESOURCES_DIR", resolvedResourcesDir, 1)
            }
        }

        if getenv("TERM") == nil {
            setenv("TERM", "xterm-ghostty", 1)
        }

        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", "ghostty", 1)
        }

        if let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap({ String(cString: $0) }) {
            let resourcesURL = URL(fileURLWithPath: resourcesDir)
            let resourcesParent = resourcesURL.deletingLastPathComponent()
            let dataDir = resourcesParent.path
            let manDir = resourcesParent.appendingPathComponent("man").path

            appendEnvPathIfMissing(
                "XDG_DATA_DIRS",
                path: dataDir,
                defaultValue: "/usr/local/share:/usr/share"
            )
            appendEnvPathIfMissing("MANPATH", path: manDir)
        }
    }

    private static func appendEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        if path.isEmpty { return }
        var current = getenv(key).flatMap { String(cString: $0) } ?? ""
        if current.isEmpty, let defaultValue {
            current = defaultValue
        }
        if current.split(separator: ":").contains(Substring(path)) {
            return
        }
        let updated = current.isEmpty ? path : "\(current):\(path)"
        setenv(key, updated, 1)
    }

    private func migrateSidebarAppearanceDefaultsIfNeeded(defaults: UserDefaults) {
        let migrationKey = "sidebarAppearanceDefaultsVersion"
        let targetVersion = 1
        guard defaults.integer(forKey: migrationKey) < targetVersion else { return }

        func normalizeHex(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "#", with: "")
                .uppercased()
        }

        func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
            abs(lhs - rhs) <= tolerance
        }

        let material = defaults.string(forKey: "sidebarMaterial") ?? SidebarMaterialOption.sidebar.rawValue
        let blendMode = defaults.string(forKey: "sidebarBlendMode") ?? SidebarBlendModeOption.behindWindow.rawValue
        let state = defaults.string(forKey: "sidebarState") ?? SidebarStateOption.followWindow.rawValue
        let tintHex = defaults.string(forKey: "sidebarTintHex") ?? "#101010"
        let tintOpacity = defaults.object(forKey: "sidebarTintOpacity") as? Double ?? 0.54
        let blurOpacity = defaults.object(forKey: "sidebarBlurOpacity") as? Double ?? 0.79
        let cornerRadius = defaults.object(forKey: "sidebarCornerRadius") as? Double ?? 0.0

        let usesLegacyDefaults =
            material == SidebarMaterialOption.sidebar.rawValue &&
            blendMode == SidebarBlendModeOption.behindWindow.rawValue &&
            state == SidebarStateOption.followWindow.rawValue &&
            normalizeHex(tintHex) == "101010" &&
            approximatelyEqual(tintOpacity, 0.54) &&
            approximatelyEqual(blurOpacity, 0.79) &&
            approximatelyEqual(cornerRadius, 0.0)

        if usesLegacyDefaults {
            let preset = SidebarPresetOption.nativeSidebar
            defaults.set(preset.rawValue, forKey: "sidebarPreset")
            defaults.set(preset.material.rawValue, forKey: "sidebarMaterial")
            defaults.set(preset.blendMode.rawValue, forKey: "sidebarBlendMode")
            defaults.set(preset.state.rawValue, forKey: "sidebarState")
            defaults.set(preset.tintHex, forKey: "sidebarTintHex")
            defaults.set(preset.tintOpacity, forKey: "sidebarTintOpacity")
            defaults.set(preset.blurOpacity, forKey: "sidebarBlurOpacity")
            defaults.set(preset.cornerRadius, forKey: "sidebarCornerRadius")
        }

        defaults.set(targetVersion, forKey: migrationKey)
    }

    var body: some Scene {
        // C11H-238 meter: count app body evaluations (meter runs only).
        let _ = GraphChurnMeter.note(.appBody)
        let _ = GraphChurnMeter.observeAppObjects(manager: workspaceManager, sidebar: sidebarState,
                                                  selection: sidebarSelectionState, notifications: notificationStore,
                                                  focusHistory: focusHistory)
        WindowGroup {
            ContentView(updateViewModel: appDelegate.updateViewModel, windowId: primaryWindowId)
                .environmentObject(workspaceManager)
                .environmentObject(notificationStore)
                .environmentObject(sidebarState)
                .environmentObject(sidebarSelectionState)
                .environment(\.chromeScaleTokens, ChromeScaleTokens(
                    multiplier: ChromeScaleSettings.multiplier(
                        presetRaw: chromeScalePresetRaw,
                        customMultiplier: chromeScaleCustomMultiplier
                    )
                ))
                .onAppear {
#if DEBUG
                    if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1" {
                        UpdateLogStore.shared.append("ui test: cmuxApp onAppear")
                    }
#endif
                    // Start the Unix socket controller for programmatic access
                    updateSocketController()
                    appDelegate.configure(workspaceManager: workspaceManager, notificationStore: notificationStore, sidebarState: sidebarState)
                    applyAppearance()
                    if ProcessInfo.processInfo.environment["CMUX_UI_TEST_SHOW_SETTINGS"] == "1" {
                        DispatchQueue.main.async {
                            appDelegate.openPreferencesWindow(debugSource: "uiTestShowSettings")
                        }
                    }
                }
                .onChange(of: appearanceMode) { _ in
                    applyAppearance()
                }
                .onChange(of: socketControlMode) { _ in
                    updateSocketController()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: CGFloat(SessionPersistencePolicy.defaultWindowWidth),
            height: CGFloat(SessionPersistencePolicy.defaultWindowHeight)
        )
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) { }

            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "menu.app.about", defaultValue: "About c11")) {
                    showAboutPanel()
                }
                Button(String(localized: "menu.app.settings", defaultValue: "c11 Settings…")) {
                    appDelegate.openPreferencesWindow(debugSource: "menu.cmdComma")
                }
                .keyboardShortcut(",", modifiers: .command)
                Button(String(localized: "menu.app.checkForUpdates", defaultValue: "Check for Updates…")) {
                    appDelegate.checkForUpdates(nil)
                }
                .disabled(!C11Identity.shouldStartSparkleUpdater(
                    bundleIdentifier: Bundle.main.bundleIdentifier ?? C11Identity.releaseBundleIdentifier,
                    feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
                ))
                InstallUpdateMenuItem(model: appDelegate.updateViewModel)
                Button(String(localized: "menu.app.reloadConfiguration", defaultValue: "Reload Configuration")) {
                    GhosttyApp.shared.reloadConfiguration(source: "menu.reload_configuration")
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                Divider()
                Button(String(localized: "menu.app.endAllSessions", defaultValue: "End All Sessions…")) {
                    appDelegate.confirmEndAllSessions()
                }
            }

            CommandMenu(String(localized: "menu.notifications.title", defaultValue: "Notifications")) {
                let snapshot = notificationMenuSnapshot

                Button(snapshot.stateHintTitle) {}
                    .disabled(true)

                if !snapshot.recentNotifications.isEmpty {
                    Divider()

                    ForEach(snapshot.recentNotifications) { notification in
                        Button(notificationMenuItemTitle(for: notification)) {
                            openNotificationFromMainMenu(notification)
                        }
                    }

                    Divider()
                }

                splitCommandButton(title: String(localized: "menu.notifications.show", defaultValue: "Show Notifications"), shortcut: showNotificationsMenuShortcut) {
                    showNotificationsPopover()
                }

                splitCommandButton(title: String(localized: "menu.notifications.jumpToUnread", defaultValue: "Jump to Latest Unread"), shortcut: jumpToUnreadMenuShortcut) {
                    appDelegate.operatorJumpToLatestUnread()
                }
                .disabled(!snapshot.hasUnreadNotifications && snapshot.flags.isEmpty && !appDelegate.hasJournalAttention)

                Button(String(localized: "menu.notifications.markAllRead", defaultValue: "Mark All Read")) {
                    notificationStore.markAllRead()
                }
                .disabled(!snapshot.hasUnreadNotifications)

                Button(String(localized: "menu.notifications.clearAll", defaultValue: "Clear All")) {
                    notificationStore.clearAll()
                }
                .disabled(!snapshot.hasNotifications)
            }

#if DEBUG
            debugMenus
#endif

            // File menu: New Workspace is the entry point for new work.
            // New Window lives in View; Close Other Tabs in Pane lives in Pane.
            // Close Tab / Close Workspace / Close Window are intentionally
            // menu-less — ⌘W / ⌘⇧W / ⌃⌘W still work through the AppDelegate
            // keyDown handler.
            CommandGroup(replacing: .newItem) {
                splitCommandButton(title: String(localized: "menu.workspace.new", defaultValue: "New Workspace"), shortcut: newWorkspaceMenuShortcut) {
                    if let appDelegate = AppDelegate.shared {
                        appDelegate.presentCreateWorkspaceSheet()
                    } else {
                        activeWorkspaceManager.addTab()
                    }
                }
                // Ticket 12: one item per machine hc has added (the build host); empty
                // without the hc backend or any added machine.
                RemoteTerminalMenuItems { machine in
                    PanelLineage.shared.withOrigin(.operator) {
                        activeWorkspaceManager.newSurface(onMachine: machine)
                    }
                }
            }

            // C11-41: Command palettes live in the c11 menu — keeping them out
            // of File matches the broader reorg's "File is minimal" stance.
            CommandGroup(after: .appInfo) {
                Divider()

                Button(String(localized: "menu.file.goToWorkspace", defaultValue: "Go to Workspace…")) {
                    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    NotificationCenter.default.post(name: .commandPaletteSwitcherRequested, object: targetWindow)
                }
                .keyboardShortcut("p", modifiers: [.command])

                Button(String(localized: "menu.file.commandPalette", defaultValue: "Command Palette…")) {
                    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    NotificationCenter.default.post(name: .commandPaletteRequested, object: targetWindow)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                // C11-181: open the A-button agent launch picker for the active
                // workspace's focused pane.
                Button(String(localized: "menu.file.launchAgentPicker", defaultValue: "Launch Agent Picker…")) {
                    AppDelegate.shared?.presentAgentPickerForActiveWorkspace()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            // AppKit auto-injects a Help menu (with its search field) whenever
            // there isn't one — and reliably suppressing it from a SwiftUI app
            // is an open battle. Embrace the slot instead: put a real action
            // here so the menu earns its space. About c11 doubles as the app's
            // identity card and a useful answer to "what is this thing?"
            CommandGroup(replacing: .help) {
                Button(String(localized: "menu.help.about", defaultValue: "About c11")) {
                    showAboutPanel()
                }
                // C11H-335: every profile's sheet is What's New in c11 2.0.
                Button(String(localized: "menu.help.whatsNew2", defaultValue: "What's New in c11 2.0")) {
                    appDelegate.presentWhatsDifferent()
                }
            }

            // C11-41 Edit menu: Find items go flat (match Safari/Mail/Notes).
            CommandGroup(after: .textEditing) {
                Button(String(localized: "menu.find.find", defaultValue: "Find…")) {
#if DEBUG
                    dlog("find.menu Cmd+F fired")
#endif
                    activeWorkspaceManager.startSearch()
                }
                .keyboardShortcut("f", modifiers: .command)

                Button(String(localized: "menu.find.findNext", defaultValue: "Find Next")) {
                    activeWorkspaceManager.findNext()
                }
                .keyboardShortcut("g", modifiers: .command)

                Button(String(localized: "menu.find.findPrevious", defaultValue: "Find Previous")) {
                    activeWorkspaceManager.findPrevious()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button(String(localized: "menu.find.useSelectionForFind", defaultValue: "Use Selection for Find")) {
                    activeWorkspaceManager.searchSelection()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!(activeWorkspaceManager.canUseSelectionForFind))

                Button(String(localized: "menu.find.hideFindBar", defaultValue: "Hide Find Bar")) {
                    activeWorkspaceManager.hideFind()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!(activeWorkspaceManager.isFindVisible))
            }

            // View menu: chrome + Appearance + window-level toggles.
            // Browser verbs, workspace switching, splits, surface focus, and
            // notifications live in their own intent-named menus.
            CommandGroup(replacing: .toolbar) {
                splitCommandButton(title: String(localized: "menu.view.newWindow", defaultValue: "New Window"), shortcut: newWindowMenuShortcut) {
                    appDelegate.openNewMainWindow(nil)
                }

                Divider()

                splitCommandButton(title: String(localized: "menu.view.toggleSidebar", defaultValue: "Toggle Sidebar"), shortcut: toggleSidebarMenuShortcut) {
                    if AppDelegate.shared?.toggleSidebarInActiveMainWindow() != true {
                        sidebarState.toggle()
                    }
                }

                Divider()

                Menu(String(localized: "menu.view.appearance", defaultValue: "Appearance")) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button {
                            appearanceMode = mode.rawValue
                        } label: {
                            if appearanceMode == mode.rawValue {
                                Label {
                                    Text(mode.displayName)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                Text(mode.displayName)
                            }
                        }
                    }
                }

                Menu(String(localized: "menu.view.titlebarControls", defaultValue: "Titlebar Controls")) {
                    Picker(String(localized: "menu.view.titlebarControls", defaultValue: "Titlebar Controls"), selection: $titlebarControlsStyle) {
                        ForEach(TitlebarControlsStyle.allCases) { style in
                            Text(style.menuTitle).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Divider()

                Toggle(
                    String(localized: "menu.view.alwaysShowShortcutHints", defaultValue: "Always Show Shortcut Hints"),
                    isOn: $alwaysShowShortcutHints
                )
            }

            // C11-41: extract the new top-level menus to a computed property so
            // the parent .commands builder stays under its 10-element cap
            // (Notifications + Debug + Update Pill push the DEBUG count high).
            workspacePaneBrowserMenus
        }
    }

#if DEBUG
    @CommandsBuilder
    private var debugMenus: some Commands {
        debugUpdatePillMenu
        debugMenu
    }

    @CommandsBuilder
    private var debugUpdatePillMenu: some Commands {
        CommandMenu("Update Pill") {
            Button("Show Update Pill") {
                appDelegate.showUpdatePill(nil)
            }
            Button("Show Restart to Update") {
                appDelegate.showUpdatePillRestartToUpdate(nil)
            }
            Button("Show Long Nightly Pill") {
                appDelegate.showUpdatePillLongNightly(nil)
            }
            Button("Show Loading State") {
                appDelegate.showUpdatePillLoading(nil)
            }
            Button("Hide Update Pill") {
                appDelegate.hideUpdatePill(nil)
            }
            Button("Automatic Update Pill") {
                appDelegate.clearUpdatePillOverride(nil)
            }
        }
    }

    @CommandsBuilder
    private var debugMenu: some Commands {
        CommandMenu("Debug") {
            Button("New Tab With Lorem Search Text") {
                appDelegate.openDebugLoremTab(nil)
            }

            Button("New Tab With Large Scrollback") {
                appDelegate.openDebugScrollbackTab(nil)
            }

            Button("Open Workspaces for All Workspace Colors") {
                appDelegate.openDebugColorComparisonWorkspaces(nil)
            }

            Button(
                String(
                    localized: "debug.menu.openStressWorkspacesWithLoadedSurfaces",
                    defaultValue: "Open Stress Workspaces and Load All Terminals"
                )
            ) {
                appDelegate.openDebugStressWorkspacesWithLoadedSurfaces(nil)
            }

            Divider()
            Button(
                String(
                    localized: "debug.theme.dumpActive",
                    defaultValue: "Debug: Dump Active Theme"
                )
            ) {
                dumpActiveThemeToMarkdownSurface()
            }

            Button {
                ThemeManager.shared.toggleRuntimeDisabled()
                themeEngineDisabledRuntime = ThemeAppStorage.bool(
                    forKey: ThemeAppStorage.Keys.engineDisabledRuntime,
                    default: false
                )
                refreshThemeDrivenChrome(reason: "debug.theme.toggleEngine")
            } label: {
                debugCheckedMenuLabel(
                    String(
                        localized: "debug.theme.toggleEngine",
                        defaultValue: "Debug: Toggle Theme Engine"
                    ),
                    checked: themeEngineDisabledRuntime
                )
            }

            Button(
                String(
                    localized: "debug.theme.showThemeFolder",
                    defaultValue: "Debug: Show Theme Folder"
                )
            ) {
                revealBundledThemeFileInFinder()
            }

            Menu(
                String(
                    localized: "debug.theme.showResolutionTrace",
                    defaultValue: "Debug: Show Resolution Trace"
                )
            ) {
                ForEach(ThemeRole.allCases, id: \.self) { role in
                    Button(role.definition.path) {
                        logThemeResolutionTrace(for: role)
                    }
                }
            }

            Menu(
                String(
                    localized: "debug.theme.m1b.menuTitle",
                    defaultValue: "Debug: Theme M1b"
                )
            ) {
                Button {
                    m1bSurfaceTitleBarMigrated.toggle()
                } label: {
                    debugCheckedMenuLabel(
                        String(
                            localized: "debug.theme.m1b.toggle.surfaceTitleBar",
                            defaultValue: "Debug: Theme M1b / Toggle PanelTitleBarView"
                        ),
                        checked: m1bSurfaceTitleBarMigrated
                    )
                }

                Button {
                    m1bBrowserChromeMigrated.toggle()
                } label: {
                    debugCheckedMenuLabel(
                        String(
                            localized: "debug.theme.m1b.toggle.browserChrome",
                            defaultValue: "Debug: Theme M1b / Toggle BrowserPanelView"
                        ),
                        checked: m1bBrowserChromeMigrated
                    )
                }

                Button {
                    m1bMarkdownChromeMigrated.toggle()
                } label: {
                    debugCheckedMenuLabel(
                        String(
                            localized: "debug.theme.m1b.toggle.markdownChrome",
                            defaultValue: "Debug: Theme M1b / Toggle MarkdownPanelView"
                        ),
                        checked: m1bMarkdownChromeMigrated
                    )
                }

                Button {
                    m1bBonsplitAppearanceMigrated.toggle()
                    refreshThemeDrivenChrome(reason: "debug.theme.toggleM1bBonsplitAppearance")
                } label: {
                    debugCheckedMenuLabel(
                        String(
                            localized: "debug.theme.m1b.toggle.bonsplitAppearance",
                            defaultValue: "Debug: Theme M1b / Toggle Workspace.bonsplitAppearance"
                        ),
                        checked: m1bBonsplitAppearanceMigrated
                    )
                }

                Button {
                    m1bSidebarTabItemMigrated.toggle()
                } label: {
                    debugCheckedMenuLabel(
                        String(
                            localized: "debug.theme.m1b.toggle.sidebarTabItem",
                            defaultValue: "Debug: Theme M1b / Toggle ContentView.WorkspaceRowView"
                        ),
                        checked: m1bSidebarTabItemMigrated
                    )
                }

                Button {
                    m1bCustomTitlebarMigrated.toggle()
                } label: {
                    debugCheckedMenuLabel(
                        String(
                            localized: "debug.theme.m1b.toggle.customTitlebar",
                            defaultValue: "Debug: Theme M1b / Toggle ContentView.customTitlebar"
                        ),
                        checked: m1bCustomTitlebarMigrated
                    )
                }

                Button {
                    m1bWorkspaceContentViewContextMigrated.toggle()
                } label: {
                    debugCheckedMenuLabel(
                        String(
                            localized: "debug.theme.m1b.toggle.workspaceContentContext",
                            defaultValue: "Debug: Theme M1b / Toggle WorkspaceContentView Context"
                        ),
                        checked: m1bWorkspaceContentViewContextMigrated
                    )
                }
            }

            Divider()
            Menu("Debug Windows") {
                Button("Debug Window Controls…") {
                    DebugWindowControlsWindowController.shared.show()
                }

                Button("Browser Import Hint Debug…") {
                    BrowserImportHintDebugWindowController.shared.show()
                }

                Button(
                    String(
                        localized: "debug.menu.browserProfilePopoverDebug",
                        defaultValue: "Browser Profile Popover Debug…"
                    )
                ) {
                    BrowserProfilePopoverDebugWindowController.shared.show()
                }

                Button("Settings/About Titlebar Debug…") {
                    SettingsAboutTitlebarDebugWindowController.shared.show()
                }

                Divider()
                Button("Sidebar Debug…") {
                    SidebarDebugWindowController.shared.show()
                }

                Button("Background Debug…") {
                    BackgroundDebugWindowController.shared.show()
                }

                Button("Menu Bar Extra Debug…") {
                    MenuBarExtraDebugWindowController.shared.show()
                }

                Divider()

                Button("Open All Debug Windows") {
                    openAllDebugWindows()
                }
            }

            Menu(
                String(
                    localized: "debug.menu.browserToolbarButtonSpacing",
                    defaultValue: "Browser Toolbar Button Spacing"
                )
            ) {
                ForEach(BrowserToolbarAccessorySpacingDebugSettings.supportedValues, id: \.self) { spacing in
                    Button {
                        browserToolbarAccessorySpacingRaw = spacing
                    } label: {
                        if browserToolbarAccessorySpacing == spacing {
                            Label {
                                Text(verbatim: "\(spacing)")
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(verbatim: "\(spacing)")
                        }
                    }
                }
            }

            Toggle(
                String(localized: "debug.devBuildBanner.show", defaultValue: "Show Dev Build Banner"),
                isOn: $showSidebarDevBuildBanner
            )

            Divider()

            Button(String(localized: "menu.updateLogs.copyUpdateLogs", defaultValue: "Copy Update Logs")) {
                appDelegate.copyUpdateLogs(nil)
            }
            Button(String(localized: "menu.updateLogs.copyFocusLogs", defaultValue: "Copy Focus Logs")) {
                appDelegate.copyFocusLogs(nil)
            }

            Divider()

            Button("Trigger Sentry Test Crash") {
                appDelegate.triggerSentryTestCrash(nil)
            }
        }
    }
#endif

    @CommandsBuilder
    private var workspacePaneBrowserMenus: some Commands {
        // C11-41 Workspace menu: absorb the old File → Workspace submenu
        // plus the workspace-switching items that used to live in View.
        CommandMenu(String(localized: "menu.workspace.title", defaultValue: "Workspace")) {
                splitCommandButton(title: String(localized: "menu.workspace.new", defaultValue: "New Workspace"), shortcut: newWorkspaceMenuShortcut) {
                    if let appDelegate = AppDelegate.shared {
                        appDelegate.presentCreateWorkspaceSheet()
                    } else {
                        activeWorkspaceManager.addTab()
                    }
                }

                Divider()

                workspaceCommandMenuContent(manager: activeWorkspaceManager)

                Divider()

                splitCommandButton(title: String(localized: "menu.workspace.next", defaultValue: "Next Workspace"), shortcut: nextWorkspaceMenuShortcut) {
                    SocketCommandContext.withContext(nil) {
                        activeWorkspaceManager.selectNextWorkspace(cause: "menu")
                        activeWorkspaceManager.acknowledgeOperatorOpen(workspaceId: activeWorkspaceManager.selectedWorkspaceId)
                    }
                }

                splitCommandButton(title: String(localized: "menu.workspace.previous", defaultValue: "Previous Workspace"), shortcut: prevWorkspaceMenuShortcut) {
                    SocketCommandContext.withContext(nil) {
                        activeWorkspaceManager.selectPreviousWorkspace(cause: "menu")
                        activeWorkspaceManager.acknowledgeOperatorOpen(workspaceId: activeWorkspaceManager.selectedWorkspaceId)
                    }
                }

                Divider()

                // Cmd+1 through Cmd+9 for workspace selection (9 = last workspace).
                ForEach(1...9, id: \.self) { number in
                    Button(String(localized: "menu.workspace.numbered", defaultValue: "Workspace \(number)")) {
                        let manager = activeWorkspaceManager
                        if let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: number, workspaceCount: manager.workspaces.count) {
                            SocketCommandContext.withContext(nil) {
                                manager.selectWorkspace(at: targetIndex, cause: "shortcut")
                                manager.acknowledgeOperatorOpen(workspaceId: manager.selectedWorkspaceId)
                            }
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
            }

            // C11-41 Pane menu: splits, directional focus, surface ops.
            CommandMenu(String(localized: "menu.pane.title", defaultValue: "Area")) {
                splitCommandButton(title: String(localized: "menu.pane.splitRight", defaultValue: "Split Right"), shortcut: splitRightMenuShortcut) {
                    performSplitFromMenu(direction: .right)
                }

                splitCommandButton(title: String(localized: "menu.pane.splitDown", defaultValue: "Split Down"), shortcut: splitDownMenuShortcut) {
                    performSplitFromMenu(direction: .down)
                }

                splitCommandButton(title: String(localized: "menu.pane.splitBrowserRight", defaultValue: "Split Browser Right"), shortcut: splitBrowserRightMenuShortcut) {
                    performBrowserSplitFromMenu(direction: .right)
                }

                splitCommandButton(title: String(localized: "menu.pane.splitBrowserDown", defaultValue: "Split Browser Down"), shortcut: splitBrowserDownMenuShortcut) {
                    performBrowserSplitFromMenu(direction: .down)
                }

                splitCommandButton(title: String(localized: "menu.pane.togglePaneZoom", defaultValue: "Toggle Area Zoom"), shortcut: toggleSplitZoomMenuShortcut) {
                    _ = activeWorkspaceManager.toggleFocusedSplitZoom()
                }

                Divider()

                splitCommandButton(title: String(localized: "menu.pane.focusLeft", defaultValue: "Focus Left"), shortcut: focusLeftMenuShortcut) {
                    activeWorkspaceManager.movePaneFocus(direction: .left)
                }

                splitCommandButton(title: String(localized: "menu.pane.focusRight", defaultValue: "Focus Right"), shortcut: focusRightMenuShortcut) {
                    activeWorkspaceManager.movePaneFocus(direction: .right)
                }

                splitCommandButton(title: String(localized: "menu.pane.focusUp", defaultValue: "Focus Up"), shortcut: focusUpMenuShortcut) {
                    activeWorkspaceManager.movePaneFocus(direction: .up)
                }

                splitCommandButton(title: String(localized: "menu.pane.focusDown", defaultValue: "Focus Down"), shortcut: focusDownMenuShortcut) {
                    activeWorkspaceManager.movePaneFocus(direction: .down)
                }

                Divider()

                Menu(String(localized: "menu.pane.newSurface", defaultValue: "New Panel")) {
                    splitCommandButton(title: String(localized: "menu.pane.newTerminal", defaultValue: "New Terminal"), shortcut: newSurfaceMenuShortcut) {
                        activeWorkspaceManager.newSurfaceAskingMachine()
                    }

                    splitCommandButton(title: String(localized: "menu.pane.newAgent", defaultValue: "New Agent"), shortcut: newAgentMenuShortcut) {
                        AppDelegate.shared?.launchDefaultAgentForActiveWorkspace()
                    }

                    splitCommandButton(title: String(localized: "menu.pane.newBrowser", defaultValue: "New Browser"), shortcut: openBrowserMenuShortcut) {
                        _ = AppDelegate.shared?.openBrowserAndFocusAddressBar(insertAtEnd: true)
                    }

                    Button(String(localized: "menu.pane.newMarkdown", defaultValue: "New Markdown")) {
                        openNewMarkdownSurface()
                    }
                }

                splitCommandButton(title: String(localized: "menu.pane.nextSurface", defaultValue: "Next Panel"), shortcut: nextSurfaceMenuShortcut) {
                    activeWorkspaceManager.selectNextSurface()
                }

                splitCommandButton(title: String(localized: "menu.pane.previousSurface", defaultValue: "Previous Panel"), shortcut: prevSurfaceMenuShortcut) {
                    activeWorkspaceManager.selectPreviousSurface()
                }

                splitCommandButton(title: String(localized: "menu.pane.renameTab", defaultValue: "Rename Panel"), shortcut: renamePanelMenuShortcut) {
                    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    _ = AppDelegate.shared?.requestCommandPaletteRenamePanel(preferredWindow: targetWindow, source: "menu.renameTab")
                }

                Divider()

                Button(String(localized: "menu.pane.closeOtherTabs", defaultValue: "Close Other Panels in Area")) {
                    closeOtherPanelsInFocusedPane()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!activeWorkspaceManager.canCloseOtherPanelsInFocusedPane())

                Divider()

                // Global font size: fans out to every terminal surface at once,
                // relative to each surface's current size (unlike per-surface Cmd +/-/0).
                splitCommandButton(title: String(localized: "menu.pane.globalFontIncrease", defaultValue: "Increase Font Size (All Terminals)"), shortcut: globalFontIncreaseMenuShortcut) {
                    GlobalTerminalFontSize.apply(.increase)
                }

                splitCommandButton(title: String(localized: "menu.pane.globalFontDecrease", defaultValue: "Decrease Font Size (All Terminals)"), shortcut: globalFontDecreaseMenuShortcut) {
                    GlobalTerminalFontSize.apply(.decrease)
                }

                splitCommandButton(title: String(localized: "menu.pane.globalFontReset", defaultValue: "Reset Font Size (All Terminals)"), shortcut: globalFontResetMenuShortcut) {
                    GlobalTerminalFontSize.apply(.reset)
                }
            }

            CommandMenu(String(localized: "menu.history.title", defaultValue: "History")) {
                splitCommandButton(title: String(localized: "menu.history.back", defaultValue: "Back"), shortcut: focusHistoryBackMenuShortcut) {
                    _ = FocusHistoryStore.shared.navigate(back: true)
                }
                .disabled(focusHistory.navigationState.back == nil)

                splitCommandButton(title: String(localized: "menu.history.forward", defaultValue: "Forward"), shortcut: focusHistoryForwardMenuShortcut) {
                    _ = FocusHistoryStore.shared.navigate(back: false)
                }
                .disabled(focusHistory.navigationState.forward == nil)
            }

            // C11-41 Browser menu: every browser-surface verb in one home.
            CommandMenu(String(localized: "menu.browser.title", defaultValue: "Browser")) {
                Button(String(localized: "menu.browser.back", defaultValue: "Back")) {
                    activeWorkspaceManager.focusedBrowserPanel?.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)

                Button(String(localized: "menu.browser.forward", defaultValue: "Forward")) {
                    activeWorkspaceManager.focusedBrowserPanel?.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)

                Button(String(localized: "menu.browser.reload", defaultValue: "Reload Page")) {
                    activeWorkspaceManager.focusedBrowserPanel?.reload()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button(String(localized: "menu.browser.zoomIn", defaultValue: "Zoom In")) {
                    _ = activeWorkspaceManager.zoomInFocusedBrowser()
                }
                .keyboardShortcut("=", modifiers: .command)

                Button(String(localized: "menu.browser.zoomOut", defaultValue: "Zoom Out")) {
                    _ = activeWorkspaceManager.zoomOutFocusedBrowser()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button(String(localized: "menu.browser.actualSize", defaultValue: "Actual Size")) {
                    _ = activeWorkspaceManager.resetZoomFocusedBrowser()
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button(String(localized: "menu.browser.reopenClosed", defaultValue: "Reopen Closed Browser Panel")) {
                    PanelLineage.shared.withOrigin(.operator) {
                        _ = activeWorkspaceManager.reopenMostRecentlyClosedBrowserPanel()
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                splitCommandButton(title: String(localized: "menu.browser.toggleDevTools", defaultValue: "Toggle Developer Tools"), shortcut: toggleBrowserDeveloperToolsMenuShortcut) {
                    let manager = activeWorkspaceManager
                    if !manager.toggleDeveloperToolsFocusedBrowser() {
                        NSSound.beep()
                    }
                }

                splitCommandButton(title: String(localized: "menu.browser.showJSConsole", defaultValue: "Show JavaScript Console"), shortcut: showBrowserJavaScriptConsoleMenuShortcut) {
                    let manager = activeWorkspaceManager
                    if !manager.showJavaScriptConsoleFocusedBrowser() {
                        NSSound.beep()
                    }
                }

                Divider()

                Button(String(localized: "menu.browser.importData", defaultValue: "Import Browser Data…")) {
                    DispatchQueue.main.async {
                        BrowserDataImportCoordinator.shared.presentImportDialog()
                    }
                }

                Button(String(localized: "menu.browser.clearHistory", defaultValue: "Clear Browser History")) {
                    BrowserHistoryStore.shared.clearHistory()
                }
            }

            // C11H-37: Window ▸ hc Core opens c11-core (c11's own hc core) in a
            // new terminal of the focused area. The only in-app UI it has.
            CommandGroup(after: .windowList) {
                Divider()
                // c11 (C11H-197): the active window's own name and theme.
                Button(String(localized: "menu.window.rename", defaultValue: "Rename Window…")) {
                    AppDelegate.shared?.promptRenameActiveMainWindow()
                }
                WindowThemeMenu()
                Divider()
                Button(String(localized: "menu.window.hcCore", defaultValue: "hc Core")) {
                    PanelLineage.shared.withOrigin(.operator) { activeWorkspaceManager.openCoreUtility() }
                }
            }
    }

    private func showAboutPanel() {
        AboutWindowController.shared.show()
    }

    private func applyAppearance() {
        let mode = AppearanceSettings.mode(for: appearanceMode)
        if appearanceMode != mode.rawValue {
            appearanceMode = mode.rawValue
        }
        Self.applyAppearance(mode)
    }

    private static func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .auto:
            NSApplication.shared.appearance = nil
        }
    }

    private func updateSocketController() {
        let mode = SocketControlSettings.effectiveMode(userMode: currentSocketMode)
        if mode != .off {
            TerminalController.shared.start(
                workspaceManager: workspaceManager,
                socketPath: SocketControlSettings.socketPath(),
                accessMode: mode
            )
        } else {
            TerminalController.shared.stop()
        }
        appDelegate.resumeStartupSessionAfterSocketChange()
    }

    private var currentSocketMode: SocketControlMode {
        SocketControlSettings.migrateMode(socketControlMode)
    }

    private var splitRightMenuShortcut: StoredShortcut {
        decodeShortcut(from: splitRightShortcutData, fallback: KeyboardShortcutSettings.Action.splitRight.defaultShortcut)
    }

    private var toggleSidebarMenuShortcut: StoredShortcut {
        decodeShortcut(from: toggleSidebarShortcutData, fallback: KeyboardShortcutSettings.Action.toggleSidebar.defaultShortcut)
    }

    private var newWorkspaceMenuShortcut: StoredShortcut {
        decodeShortcut(from: newWorkspaceShortcutData, fallback: KeyboardShortcutSettings.Action.newWorkspace.defaultShortcut)
    }

    private var newWindowMenuShortcut: StoredShortcut {
        decodeShortcut(from: newWindowShortcutData, fallback: KeyboardShortcutSettings.Action.newWindow.defaultShortcut)
    }

    private var openFolderMenuShortcut: StoredShortcut {
        decodeShortcut(from: openFolderShortcutData, fallback: KeyboardShortcutSettings.Action.openFolder.defaultShortcut)
    }

    private var showNotificationsMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: showNotificationsShortcutData,
            fallback: KeyboardShortcutSettings.Action.showNotifications.defaultShortcut
        )
    }

    private var jumpToUnreadMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: jumpToUnreadShortcutData,
            fallback: KeyboardShortcutSettings.Action.jumpToUnread.defaultShortcut
        )
    }

    private var nextSurfaceMenuShortcut: StoredShortcut {
        decodeShortcut(from: nextSurfaceShortcutData, fallback: KeyboardShortcutSettings.Action.nextSurface.defaultShortcut)
    }

    private var prevSurfaceMenuShortcut: StoredShortcut {
        decodeShortcut(from: prevSurfaceShortcutData, fallback: KeyboardShortcutSettings.Action.prevSurface.defaultShortcut)
    }

    private var nextWorkspaceMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: nextWorkspaceShortcutData,
            fallback: KeyboardShortcutSettings.Action.nextSidebarWorkspace.defaultShortcut
        )
    }

    private var prevWorkspaceMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: prevWorkspaceShortcutData,
            fallback: KeyboardShortcutSettings.Action.prevSidebarWorkspace.defaultShortcut
        )
    }

    private var focusHistoryBackMenuShortcut: StoredShortcut {
        decodeShortcut(from: focusHistoryBackShortcutData, fallback: KeyboardShortcutSettings.Action.focusHistoryBack.defaultShortcut)
    }

    private var focusHistoryForwardMenuShortcut: StoredShortcut {
        decodeShortcut(from: focusHistoryForwardShortcutData, fallback: KeyboardShortcutSettings.Action.focusHistoryForward.defaultShortcut)
    }

    private var splitDownMenuShortcut: StoredShortcut {
        decodeShortcut(from: splitDownShortcutData, fallback: KeyboardShortcutSettings.Action.splitDown.defaultShortcut)
    }

    private var toggleBrowserDeveloperToolsMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: toggleBrowserDeveloperToolsShortcutData,
            fallback: KeyboardShortcutSettings.Action.toggleBrowserDeveloperTools.defaultShortcut
        )
    }

    private var showBrowserJavaScriptConsoleMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: showBrowserJavaScriptConsoleShortcutData,
            fallback: KeyboardShortcutSettings.Action.showBrowserJavaScriptConsole.defaultShortcut
        )
    }

    private var splitBrowserRightMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: splitBrowserRightShortcutData,
            fallback: KeyboardShortcutSettings.Action.splitBrowserRight.defaultShortcut
        )
    }

    private var splitBrowserDownMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: splitBrowserDownShortcutData,
            fallback: KeyboardShortcutSettings.Action.splitBrowserDown.defaultShortcut
        )
    }

    private var renameWorkspaceMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: renameWorkspaceShortcutData,
            fallback: KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        )
    }

    private var closeWorkspaceMenuShortcut: StoredShortcut {
        decodeShortcut(
            from: closeWorkspaceShortcutData,
            fallback: KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        )
    }

    private var focusLeftMenuShortcut: StoredShortcut {
        decodeShortcut(from: focusLeftShortcutData, fallback: KeyboardShortcutSettings.Action.focusLeft.defaultShortcut)
    }

    private var focusRightMenuShortcut: StoredShortcut {
        decodeShortcut(from: focusRightShortcutData, fallback: KeyboardShortcutSettings.Action.focusRight.defaultShortcut)
    }

    private var focusUpMenuShortcut: StoredShortcut {
        decodeShortcut(from: focusUpShortcutData, fallback: KeyboardShortcutSettings.Action.focusUp.defaultShortcut)
    }

    private var focusDownMenuShortcut: StoredShortcut {
        decodeShortcut(from: focusDownShortcutData, fallback: KeyboardShortcutSettings.Action.focusDown.defaultShortcut)
    }

    private var toggleSplitZoomMenuShortcut: StoredShortcut {
        decodeShortcut(from: toggleSplitZoomShortcutData, fallback: KeyboardShortcutSettings.Action.toggleSplitZoom.defaultShortcut)
    }

    private var newSurfaceMenuShortcut: StoredShortcut {
        decodeShortcut(from: newSurfaceShortcutData, fallback: KeyboardShortcutSettings.Action.newSurface.defaultShortcut)
    }

    private var newAgentMenuShortcut: StoredShortcut {
        decodeShortcut(from: newAgentShortcutData, fallback: KeyboardShortcutSettings.Action.newAgent.defaultShortcut)
    }

    private var openBrowserMenuShortcut: StoredShortcut {
        decodeShortcut(from: openBrowserShortcutData, fallback: KeyboardShortcutSettings.Action.openBrowser.defaultShortcut)
    }

    private var renamePanelMenuShortcut: StoredShortcut {
        decodeShortcut(from: renamePanelShortcutData, fallback: KeyboardShortcutSettings.Action.renamePanel.defaultShortcut)
    }

    private var globalFontIncreaseMenuShortcut: StoredShortcut {
        decodeShortcut(from: globalFontIncreaseShortcutData, fallback: KeyboardShortcutSettings.Action.globalFontIncrease.defaultShortcut)
    }

    private var globalFontDecreaseMenuShortcut: StoredShortcut {
        decodeShortcut(from: globalFontDecreaseShortcutData, fallback: KeyboardShortcutSettings.Action.globalFontDecrease.defaultShortcut)
    }

    private var globalFontResetMenuShortcut: StoredShortcut {
        decodeShortcut(from: globalFontResetShortcutData, fallback: KeyboardShortcutSettings.Action.globalFontReset.defaultShortcut)
    }

    private func openNewMarkdownSurface() {
        let originScope = PanelLineage.shared.enterOrigin(.operator)
        defer { PanelLineage.shared.exitOrigin(originScope) }
        guard let workspace = activeWorkspaceManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            NSSound.beep()
            return
        }
        _ = workspace.newMarkdownPanel(inPane: paneId, focus: true)
    }

    private var notificationMenuSnapshot: NotificationMenuSnapshot {
        NotificationMenuSnapshotBuilder.make(notifications: notificationStore.notifications)
    }

    private var activeWorkspaceManager: WorkspaceManager {
        AppDelegate.shared?.synchronizeActiveMainWindowContext(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        ) ?? workspaceManager
    }

    private func decodeShortcut(from data: Data, fallback: StoredShortcut) -> StoredShortcut {
        guard !data.isEmpty,
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return fallback
        }
        return shortcut
    }

    private func notificationMenuItemTitle(for notification: TerminalNotification) -> String {
        let tabTitle = appDelegate.tabTitle(for: notification.workspaceId)
        return MenuBarNotificationLineFormatter.menuTitle(notification: notification, tabTitle: tabTitle)
    }

    private func openNotificationFromMainMenu(_ notification: TerminalNotification) {
        _ = appDelegate.operatorOpenNotification(
            workspaceId: notification.workspaceId,
            surfaceId: notification.surfaceId,
            notificationId: notification.id
        )
    }

    private func performSplitFromMenu(direction: SplitDirection) {
        let originScope = PanelLineage.shared.enterOrigin(.operator)
        defer { PanelLineage.shared.exitOrigin(originScope) }
        if AppDelegate.shared?.performSplitShortcut(direction: direction) == true {
            return
        }
        workspaceManager.createSplit(direction: direction)
    }

    private func performBrowserSplitFromMenu(direction: SplitDirection) {
        let originScope = PanelLineage.shared.enterOrigin(.operator)
        defer { PanelLineage.shared.exitOrigin(originScope) }
        if AppDelegate.shared?.performBrowserSplitShortcut(direction: direction) == true {
            return
        }
        _ = workspaceManager.createBrowserSplit(direction: direction)
    }

    private func selectedWorkspaceIndex(in manager: WorkspaceManager, workspaceId: UUID) -> Int? {
        manager.workspaces.firstIndex { $0.id == workspaceId }
    }

    private func selectedWorkspaceWindowMoveTargets(in manager: WorkspaceManager) -> [AppDelegate.WindowMoveTarget] {
        let referenceWindowId = AppDelegate.shared?.windowId(for: manager)
        return AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
    }

    private func toggleSelectedWorkspacePinned(in manager: WorkspaceManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        manager.setPinned(workspace, pinned: !workspace.isPinned)
    }

    private func clearSelectedWorkspaceCustomName(in manager: WorkspaceManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        manager.clearCustomTitle(workspaceId: workspace.id)
    }

    /// C11H-342: one sidebar step, as the row's Move Up/Down actions take
    /// (an ungrouped workspace passes a group; a member stays in its group).
    private func moveSelectedWorkspace(in manager: WorkspaceManager, by delta: Int) {
        guard let workspace = manager.selectedWorkspace else { return }
        guard manager.stepWorkspaceInSidebar(workspace.id, by: delta) else { return }
        manager.selectWorkspace(workspace)
    }

    private func moveSelectedWorkspaceToTop(in manager: WorkspaceManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        manager.moveWorkspacesToTop([workspace.id])
        manager.selectWorkspace(workspace)
    }

    private func moveSelectedWorkspace(in manager: WorkspaceManager, toWindow windowId: UUID) {
        guard let workspace = manager.selectedWorkspace else { return }
        _ = AppDelegate.shared?.moveWorkspaceToWindow(workspaceId: workspace.id, windowId: windowId, focus: true)
    }

    private func moveSelectedWorkspaceToNewWindow(in manager: WorkspaceManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        _ = AppDelegate.shared?.moveWorkspaceToNewWindow(workspaceId: workspace.id, focus: true)
    }

    private func selectedWorkspaceHasUnreadNotifications(in manager: WorkspaceManager) -> Bool {
        guard let workspaceId = manager.selectedWorkspace?.id else { return false }
        return notificationStore.notifications.contains { $0.workspaceId == workspaceId && !$0.isRead }
    }

    private func selectedWorkspaceHasReadNotifications(in manager: WorkspaceManager) -> Bool {
        guard let workspaceId = manager.selectedWorkspace?.id else { return false }
        return notificationStore.notifications.contains { $0.workspaceId == workspaceId && $0.isRead }
    }

    private func markSelectedWorkspaceRead(in manager: WorkspaceManager) {
        guard let workspaceId = manager.selectedWorkspace?.id else { return }
        notificationStore.markRead(forWorkspaceId: workspaceId)
    }

    private func markSelectedWorkspaceUnread(in manager: WorkspaceManager) {
        guard let workspaceId = manager.selectedWorkspace?.id else { return }
        notificationStore.markUnread(forWorkspaceId: workspaceId)
    }

    @ViewBuilder
    private func workspaceCommandMenuContent(manager: WorkspaceManager) -> some View {
        let workspace = manager.selectedWorkspace
        let workspaceIndex = workspace.flatMap { selectedWorkspaceIndex(in: manager, workspaceId: $0.id) }
        let windowMoveTargets = selectedWorkspaceWindowMoveTargets(in: manager)

        Button(
            workspace?.isPinned == true
                ? String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace")
                : String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace")
        ) {
            toggleSelectedWorkspacePinned(in: manager)
        }
        .disabled(workspace == nil)

        Button(String(localized: "menu.view.renameWorkspace", defaultValue: "Rename Workspace…")) {
            _ = AppDelegate.shared?.requestRenameWorkspaceViaCommandPalette()
        }
        .disabled(workspace == nil)

        if workspace?.hasCustomTitle == true {
            Button(String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")) {
                clearSelectedWorkspaceCustomName(in: manager)
            }
        }

        Divider()

        // C11H-342: enabled by the same sidebar step the action performs.
        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveSelectedWorkspace(in: manager, by: -1)
        }
        .disabled(!(workspace.map { manager.canStepWorkspaceInSidebar($0.id, by: -1) } ?? false))

        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveSelectedWorkspace(in: manager, by: 1)
        }
        .disabled(!(workspace.map { manager.canStepWorkspaceInSidebar($0.id, by: 1) } ?? false))

        Button(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")) {
            moveSelectedWorkspaceToTop(in: manager)
        }
        .disabled(workspace == nil || workspaceIndex == 0)

        Menu(String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")) {
            Button(String(localized: "contextMenu.newWindow", defaultValue: "New Window")) {
                moveSelectedWorkspaceToNewWindow(in: manager)
            }
            .disabled(workspace == nil)

            if !windowMoveTargets.isEmpty {
                Divider()
            }

            ForEach(windowMoveTargets) { target in
                Button(target.label) {
                    moveSelectedWorkspace(in: manager, toWindow: target.windowId)
                }
                .disabled(target.isCurrentWindow || workspace == nil)
            }
        }
        .disabled(workspace == nil)

        Divider()

        Button(String(localized: "menu.file.closeWorkspace", defaultValue: "Close Workspace")) {
            manager.closeCurrentWorkspaceWithConfirmation()
        }
        .disabled(workspace == nil)

        Divider()

        // C11-25: hibernate / resume the workspace. Browser surfaces
        // capture a snapshot, terminate their WebContent processes, and
        // render a placeholder until resume; terminals stay on the auto
        // throttle path. The menu flips between Hibernate and Resume
        // based on `workspace.isHibernated`.
        if workspace?.isHibernated == true {
            Button(String(localized: "contextMenu.resumeWorkspace", defaultValue: "Resume Workspace")) {
                workspace?.resume()
            }
            .disabled(workspace == nil)
        } else {
            Button(String(localized: "contextMenu.hibernateWorkspace", defaultValue: "Hibernate Workspace")) {
                workspace?.hibernate()
            }
            .disabled(workspace == nil)
            .help(String(
                localized: "contextMenu.hibernateWorkspaceTooltip",
                defaultValue: "Suspends browser panels in this workspace. Terminals stay on auto-throttle (already low-CPU when the workspace isn't focused)."
            ))
        }

        Divider()

        Button(String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read")) {
            markSelectedWorkspaceRead(in: manager)
        }
        .disabled(!selectedWorkspaceHasUnreadNotifications(in: manager))

        Button(String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread")) {
            markSelectedWorkspaceUnread(in: manager)
        }
        .disabled(!selectedWorkspaceHasReadNotifications(in: manager))
    }

    @ViewBuilder
    private func splitCommandButton(title: String, shortcut: StoredShortcut, action: @escaping () -> Void) -> some View {
        if let key = shortcut.keyEquivalent {
            Button(title) { Self.runOperatorMenuAction(action) }
                .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(title) { Self.runOperatorMenuAction(action) }
        }
    }

    /// A menu item the operator chose: no socket context, and panels it
    /// creates record the operator as their origin (C11H-260).
    @MainActor
    private static func runOperatorMenuAction(_ action: () -> Void) {
        SocketCommandContext.withContext(nil) {
            PanelLineage.shared.withOrigin(.operator, operation: action)
        }
    }

    private func closePanelOrWindow() {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           cmuxWindowShouldOwnCloseShortcut(window) {
            window.performClose(nil)
            return
        }
        activeWorkspaceManager.closeCurrentPanelWithConfirmation()
    }

    private func closeOtherPanelsInFocusedPane() {
        activeWorkspaceManager.closeOtherPanelsInFocusedPaneWithConfirmation()
    }

    private func closeWorkspaceOrWindow() {
        activeWorkspaceManager.closeCurrentWorkspaceWithConfirmation()
    }

    private func showNotificationsPopover() {
        AppDelegate.shared?.toggleNotificationsPopover(animated: false)
    }

    @ViewBuilder
    private func debugCheckedMenuLabel(_ title: String, checked: Bool) -> some View {
        if checked {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "checkmark")
            }
        } else {
            Text(title)
        }
    }

    @MainActor
    private func activeThemeDebugContext() -> ThemeContext {
        ThemeManager.shared.makeContext(
            workspaceColor: activeWorkspaceManager.selectedWorkspace?.customColor,
            colorScheme: ThemeManager.currentColorScheme(),
            isWindowFocused: NSApp.keyWindow?.isKeyWindow ?? true
        )
    }

    @MainActor
    private func dumpActiveThemeToMarkdownSurface() {
        guard let workspace = activeWorkspaceManager.selectedWorkspace else {
            ThemeDiagnostics.engine("debug dump active theme skipped: no selected workspace")
            return
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            ThemeDiagnostics.engine("debug dump active theme skipped: no target pane")
            return
        }

        let context = activeThemeDebugContext()
        let json = ThemeManager.shared.dumpActiveThemeJSON(context: context)
        let markdown = "```json\n\(json)\n```\n"

        let filename = "cmux-theme-dump-\(Int(Date().timeIntervalSince1970)).md"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            if workspace.newMarkdownPanel(inPane: paneId, filePath: fileURL.path, focus: true) == nil {
                ThemeDiagnostics.engine("debug dump active theme failed: unable to open markdown surface")
            }
        } catch {
            ThemeDiagnostics.engine("debug dump active theme failed to write markdown: \(error.localizedDescription)")
        }
    }

    private func revealBundledThemeFileInFinder() {
        guard let fileURL = Bundle.main.resourceURL?
            .appendingPathComponent(ThemeManager.bundledThemesDirectoryName, isDirectory: true)
            .appendingPathComponent("stage11.toml") else {
            ThemeDiagnostics.engine("debug show theme folder skipped: bundle resources unavailable")
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            ThemeDiagnostics.engine("debug show theme folder skipped: stage11.toml not found at \(fileURL.path)")
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @MainActor
    private func logThemeResolutionTrace(for role: ThemeRole) {
        let trace = ThemeManager.shared.resolutionTrace(for: role, context: activeThemeDebugContext())
        ThemeDiagnostics.engine("resolution trace \(trace)")
        NSLog("Theme resolution trace: %@", trace)
    }

    @MainActor
    private func refreshThemeDrivenChrome(reason: String) {
        let backgroundColor = GhosttyApp.shared.defaultBackgroundColor
        let backgroundOpacity = GhosttyApp.shared.defaultBackgroundOpacity
        for workspace in activeWorkspaceManager.workspaces {
            workspace.applyGhosttyChrome(
                backgroundColor: backgroundColor,
                backgroundOpacity: backgroundOpacity,
                reason: reason
            )
        }
    }

    private func openAllDebugWindows() {
        BrowserImportHintDebugWindowController.shared.show()
        BrowserProfilePopoverDebugWindowController.shared.show()
        SettingsAboutTitlebarDebugWindowController.shared.show()
        SidebarDebugWindowController.shared.show()
        BackgroundDebugWindowController.shared.show()
        MenuBarExtraDebugWindowController.shared.show()
    }
}

private let cmuxAuxiliaryWindowIdentifiers: Set<String> = [
    "cmux.settings",
    "cmux.about",
    "cmux.licenses",
    "cmux.browser-popup",
    "cmux.settingsAboutTitlebarDebug",
    "cmux.debugWindowControls",
    "cmux.browserImportHintDebug",
    "cmux.sidebarDebug",
    "cmux.menubarDebug",
    "cmux.backgroundDebug",
]

/// Returns whether the given window should handle the standard close shortcut
/// as a standalone auxiliary window instead of routing it through workspace or
/// panel-close behavior.
func cmuxWindowShouldOwnCloseShortcut(_ window: NSWindow?) -> Bool {
    guard let identifier = window?.identifier?.rawValue else { return false }
    return cmuxAuxiliaryWindowIdentifiers.contains(identifier)
}

private enum SettingsAboutWindowKind: String, CaseIterable, Identifiable {
    case settings
    case about

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .settings:
            return "Settings Window"
        case .about:
            return "About Window"
        }
    }

    var windowIdentifier: String {
        switch self {
        case .settings:
            return "cmux.settings"
        case .about:
            return "cmux.about"
        }
    }

    var fallbackTitle: String {
        switch self {
        case .settings:
            return String(localized: "settings.title", defaultValue: "c11 Settings")
        case .about:
            return String(localized: "menu.app.about", defaultValue: "About c11")
        }
    }

    var minimumSize: NSSize {
        switch self {
        case .settings:
            return NSSize(width: 860, height: 520)
        case .about:
            return NSSize(width: 360, height: 520)
        }
    }
}

private enum TitlebarVisibilityOption: String, CaseIterable, Identifiable {
    case hidden
    case visible

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .hidden:
            return "Hidden"
        case .visible:
            return "Visible"
        }
    }

    var windowValue: NSWindow.TitleVisibility {
        switch self {
        case .hidden:
            return .hidden
        case .visible:
            return .visible
        }
    }
}

private enum TitlebarToolbarStyleOption: String, CaseIterable, Identifiable {
    case automatic
    case expanded
    case preference
    case unified
    case unifiedCompact

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .expanded:
            return "Expanded"
        case .preference:
            return "Preference"
        case .unified:
            return "Unified"
        case .unifiedCompact:
            return "Unified Compact"
        }
    }

    var windowValue: NSWindow.ToolbarStyle {
        switch self {
        case .automatic:
            return .automatic
        case .expanded:
            return .expanded
        case .preference:
            return .preference
        case .unified:
            return .unified
        case .unifiedCompact:
            return .unifiedCompact
        }
    }
}

private struct SettingsAboutTitlebarDebugOptions: Equatable {
    var overridesEnabled: Bool
    var windowTitle: String
    var titleVisibility: TitlebarVisibilityOption
    var titlebarAppearsTransparent: Bool
    var movableByWindowBackground: Bool
    var titled: Bool
    var closable: Bool
    var miniaturizable: Bool
    var resizable: Bool
    var fullSizeContentView: Bool
    var showToolbar: Bool
    var toolbarStyle: TitlebarToolbarStyleOption

    static func defaults(for kind: SettingsAboutWindowKind) -> SettingsAboutTitlebarDebugOptions {
        switch kind {
        case .settings:
            return SettingsAboutTitlebarDebugOptions(
                overridesEnabled: false,
                windowTitle: String(localized: "settings.title", defaultValue: "c11 Settings"),
                titleVisibility: .hidden,
                titlebarAppearsTransparent: true,
                movableByWindowBackground: true,
                titled: true,
                closable: true,
                miniaturizable: true,
                resizable: true,
                fullSizeContentView: true,
                showToolbar: false,
                toolbarStyle: .unifiedCompact
            )
        case .about:
            return SettingsAboutTitlebarDebugOptions(
                overridesEnabled: false,
                windowTitle: String(localized: "menu.app.about", defaultValue: "About c11"),
                titleVisibility: .hidden,
                titlebarAppearsTransparent: true,
                movableByWindowBackground: false,
                titled: true,
                closable: true,
                miniaturizable: true,
                resizable: false,
                fullSizeContentView: false,
                showToolbar: false,
                toolbarStyle: .automatic
            )
        }
    }
}

@MainActor
private final class SettingsAboutTitlebarDebugStore: ObservableObject {
    static let shared = SettingsAboutTitlebarDebugStore()

    @Published var settingsOptions = SettingsAboutTitlebarDebugOptions.defaults(for: .settings) {
        didSet { applyToOpenWindows(for: .settings) }
    }
    @Published var aboutOptions = SettingsAboutTitlebarDebugOptions.defaults(for: .about) {
        didSet { applyToOpenWindows(for: .about) }
    }

    private init() {}

    func options(for kind: SettingsAboutWindowKind) -> SettingsAboutTitlebarDebugOptions {
        switch kind {
        case .settings:
            return settingsOptions
        case .about:
            return aboutOptions
        }
    }

    func update(_ newValue: SettingsAboutTitlebarDebugOptions, for kind: SettingsAboutWindowKind) {
        switch kind {
        case .settings:
            settingsOptions = newValue
        case .about:
            aboutOptions = newValue
        }
    }

    func reset(_ kind: SettingsAboutWindowKind) {
        update(SettingsAboutTitlebarDebugOptions.defaults(for: kind), for: kind)
    }

    func applyToOpenWindows(for kind: SettingsAboutWindowKind) {
        for window in NSApp.windows where window.identifier?.rawValue == kind.windowIdentifier {
            apply(options(for: kind), to: window, for: kind)
        }
    }

    func applyToOpenWindows() {
        applyToOpenWindows(for: .settings)
        applyToOpenWindows(for: .about)
    }

    func applyCurrentOptions(to window: NSWindow, for kind: SettingsAboutWindowKind) {
        apply(options(for: kind), to: window, for: kind)
    }

    func copyConfigToPasteboard() {
        let settings = options(for: .settings)
        let about = options(for: .about)
        let payload = """
        # Settings/About Titlebar Debug
        settings.overridesEnabled=\(settings.overridesEnabled)
        settings.title=\(settings.windowTitle)
        settings.titleVisibility=\(settings.titleVisibility.rawValue)
        settings.titlebarAppearsTransparent=\(settings.titlebarAppearsTransparent)
        settings.movableByWindowBackground=\(settings.movableByWindowBackground)
        settings.titled=\(settings.titled)
        settings.closable=\(settings.closable)
        settings.miniaturizable=\(settings.miniaturizable)
        settings.resizable=\(settings.resizable)
        settings.fullSizeContentView=\(settings.fullSizeContentView)
        settings.showToolbar=\(settings.showToolbar)
        settings.toolbarStyle=\(settings.toolbarStyle.rawValue)
        about.overridesEnabled=\(about.overridesEnabled)
        about.title=\(about.windowTitle)
        about.titleVisibility=\(about.titleVisibility.rawValue)
        about.titlebarAppearsTransparent=\(about.titlebarAppearsTransparent)
        about.movableByWindowBackground=\(about.movableByWindowBackground)
        about.titled=\(about.titled)
        about.closable=\(about.closable)
        about.miniaturizable=\(about.miniaturizable)
        about.resizable=\(about.resizable)
        about.fullSizeContentView=\(about.fullSizeContentView)
        about.showToolbar=\(about.showToolbar)
        about.toolbarStyle=\(about.toolbarStyle.rawValue)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    private func apply(_ options: SettingsAboutTitlebarDebugOptions, to window: NSWindow, for kind: SettingsAboutWindowKind) {
        let effective = options.overridesEnabled ? options : SettingsAboutTitlebarDebugOptions.defaults(for: kind)
        let resolvedTitle = effective.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        window.title = resolvedTitle.isEmpty ? kind.fallbackTitle : resolvedTitle
        window.titleVisibility = effective.titleVisibility.windowValue
        window.titlebarAppearsTransparent = effective.titlebarAppearsTransparent
        window.isMovableByWindowBackground = effective.movableByWindowBackground
        window.toolbarStyle = effective.toolbarStyle.windowValue

        if effective.showToolbar {
            ensureToolbar(on: window, kind: kind)
        } else if window.toolbar != nil {
            window.toolbar = nil
        }

        var styleMask = window.styleMask
        setStyleMaskBit(&styleMask, .titled, enabled: effective.titled)
        setStyleMaskBit(&styleMask, .closable, enabled: effective.closable)
        setStyleMaskBit(&styleMask, .miniaturizable, enabled: effective.miniaturizable)
        setStyleMaskBit(&styleMask, .resizable, enabled: effective.resizable)
        setStyleMaskBit(&styleMask, .fullSizeContentView, enabled: effective.fullSizeContentView)
        window.styleMask = styleMask

        let maxSize = effective.resizable ? NSSize(width: 8192, height: 8192) : kind.minimumSize
        window.minSize = kind.minimumSize
        window.maxSize = maxSize
        window.contentMinSize = kind.minimumSize
        window.contentMaxSize = maxSize
        window.invalidateShadow()
        AppDelegate.shared?.applyWindowDecorations(to: window)
    }

    private func ensureToolbar(on window: NSWindow, kind: SettingsAboutWindowKind) {
        guard window.toolbar == nil else { return }
        let identifier = NSToolbar.Identifier("cmux.debug.titlebar.\(kind.rawValue)")
        let toolbar = NSToolbar(identifier: identifier)
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
    }

    private func setStyleMaskBit(
        _ styleMask: inout NSWindow.StyleMask,
        _ bit: NSWindow.StyleMask,
        enabled: Bool
    ) {
        if enabled {
            styleMask.insert(bit)
        } else {
            styleMask.remove(bit)
        }
    }
}

private final class SettingsAboutTitlebarDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsAboutTitlebarDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 690),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings/About Titlebar Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.settingsAboutTitlebarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SettingsAboutTitlebarDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        SettingsAboutTitlebarDebugStore.shared.applyToOpenWindows()
    }
}

private struct SettingsAboutTitlebarDebugView: View {
    @ObservedObject private var store = SettingsAboutTitlebarDebugStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings/About Titlebar Debug")
                    .font(.headline)

                editor(for: .settings)
                editor(for: .about)

                GroupBox("Actions") {
                    HStack(spacing: 10) {
                        Button("Reset All") {
                            store.reset(.settings)
                            store.reset(.about)
                        }
                        Button("Reapply to Open Windows") {
                            store.applyToOpenWindows()
                        }
                        Button("Copy Config") {
                            store.copyConfigToPasteboard()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func editor(for kind: SettingsAboutWindowKind) -> some View {
        let overridesEnabled = binding(for: kind, keyPath: \.overridesEnabled)

        return GroupBox(kind.displayTitle) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable Debug Overrides", isOn: overridesEnabled)

                Text("When disabled, c11 uses normal default titlebar behavior for this window.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Window Title")
                        TextField("", text: binding(for: kind, keyPath: \.windowTitle))
                    }

                    HStack(spacing: 10) {
                        Picker("Title Visibility", selection: binding(for: kind, keyPath: \.titleVisibility)) {
                            ForEach(TitlebarVisibilityOption.allCases) { option in
                                Text(option.displayTitle).tag(option)
                            }
                        }
                        Picker("Toolbar Style", selection: binding(for: kind, keyPath: \.toolbarStyle)) {
                            ForEach(TitlebarToolbarStyleOption.allCases) { option in
                                Text(option.displayTitle).tag(option)
                            }
                        }
                    }

                    Toggle("Show Toolbar", isOn: binding(for: kind, keyPath: \.showToolbar))
                    Toggle("Transparent Titlebar", isOn: binding(for: kind, keyPath: \.titlebarAppearsTransparent))
                    Toggle("Movable by Window Background", isOn: binding(for: kind, keyPath: \.movableByWindowBackground))

                    Divider()

                    Text("Style Mask")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Titled", isOn: binding(for: kind, keyPath: \.titled))
                    Toggle("Closable", isOn: binding(for: kind, keyPath: \.closable))
                    Toggle("Miniaturizable", isOn: binding(for: kind, keyPath: \.miniaturizable))
                    Toggle("Resizable", isOn: binding(for: kind, keyPath: \.resizable))
                    Toggle("Full Size Content View", isOn: binding(for: kind, keyPath: \.fullSizeContentView))

                    HStack(spacing: 10) {
                        Button("Reset \(kind == .settings ? "Settings" : "About")") {
                            store.reset(kind)
                        }
                        Button("Apply Now") {
                            store.applyToOpenWindows(for: kind)
                        }
                    }
                }
                .disabled(!overridesEnabled.wrappedValue)
                .opacity(overridesEnabled.wrappedValue ? 1 : 0.75)
            }
            .padding(.top, 2)
        }
    }

    private func binding<Value>(
        for kind: SettingsAboutWindowKind,
        keyPath: WritableKeyPath<SettingsAboutTitlebarDebugOptions, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.options(for: kind)[keyPath: keyPath] },
            set: { newValue in
                var updated = store.options(for: kind)
                updated[keyPath: keyPath] = newValue
                store.update(updated, for: kind)
            }
        )
    }
}

private enum DebugWindowConfigSnapshot {
    static func copyCombinedToPasteboard(defaults: UserDefaults = .standard) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(combinedPayload(defaults: defaults), forType: .string)
    }

    static func combinedPayload(defaults: UserDefaults = .standard) -> String {
        let sidebarPayload = """
        sidebarPreset=\(stringValue(defaults, key: "sidebarPreset", fallback: SidebarPresetOption.nativeSidebar.rawValue))
        sidebarMaterial=\(stringValue(defaults, key: "sidebarMaterial", fallback: SidebarMaterialOption.sidebar.rawValue))
        sidebarBlendMode=\(stringValue(defaults, key: "sidebarBlendMode", fallback: SidebarBlendModeOption.withinWindow.rawValue))
        sidebarState=\(stringValue(defaults, key: "sidebarState", fallback: SidebarStateOption.followWindow.rawValue))
        sidebarBlurOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "sidebarBlurOpacity", fallback: 1.0)))
        sidebarTintHex=\(stringValue(defaults, key: "sidebarTintHex", fallback: "#000000"))
        sidebarTintHexLight=\(stringValue(defaults, key: "sidebarTintHexLight", fallback: "(nil)"))
        sidebarTintHexDark=\(stringValue(defaults, key: "sidebarTintHexDark", fallback: "(nil)"))
        sidebarTintOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "sidebarTintOpacity", fallback: 0.18)))
        sidebarCornerRadius=\(String(format: "%.1f", doubleValue(defaults, key: "sidebarCornerRadius", fallback: 0.0)))
        sidebarBranchVerticalLayout=\(boolValue(defaults, key: SidebarBranchLayoutSettings.key, fallback: SidebarBranchLayoutSettings.defaultVerticalLayout))
        sidebarActiveTabIndicatorStyle=\(stringValue(defaults, key: SidebarActiveWorkspaceIndicatorSettings.styleKey, fallback: SidebarActiveWorkspaceIndicatorSettings.defaultStyle.rawValue))
        sidebarDevBuildBannerVisible=\(boolValue(defaults, key: DevBuildBannerDebugSettings.sidebarBannerVisibleKey, fallback: DevBuildBannerDebugSettings.defaultShowSidebarBanner))
        shortcutHintTitlebarXOffset=\(String(format: "%.1f", doubleValue(defaults, key: ShortcutHintDebugSettings.titlebarHintXKey, fallback: ShortcutHintDebugSettings.defaultTitlebarHintX)))
        shortcutHintTitlebarYOffset=\(String(format: "%.1f", doubleValue(defaults, key: ShortcutHintDebugSettings.titlebarHintYKey, fallback: ShortcutHintDebugSettings.defaultTitlebarHintY)))
        shortcutHintPaneTabXOffset=\(String(format: "%.1f", doubleValue(defaults, key: ShortcutHintDebugSettings.paneHintXKey, fallback: ShortcutHintDebugSettings.defaultPaneHintX)))
        shortcutHintPaneTabYOffset=\(String(format: "%.1f", doubleValue(defaults, key: ShortcutHintDebugSettings.paneHintYKey, fallback: ShortcutHintDebugSettings.defaultPaneHintY)))
        shortcutHintAlwaysShow=\(boolValue(defaults, key: ShortcutHintDebugSettings.alwaysShowHintsKey, fallback: ShortcutHintDebugSettings.defaultAlwaysShowHints))
        shortcutHintShowOnCommandHold=\(boolValue(defaults, key: ShortcutHintDebugSettings.showHintsOnCommandHoldKey, fallback: ShortcutHintDebugSettings.defaultShowHintsOnCommandHold))
        """

        let backgroundPayload = """
        bgGlassEnabled=\(boolValue(defaults, key: "bgGlassEnabled", fallback: false))
        bgGlassMaterial=\(stringValue(defaults, key: "bgGlassMaterial", fallback: "hudWindow"))
        bgGlassTintHex=\(stringValue(defaults, key: "bgGlassTintHex", fallback: "#000000"))
        bgGlassTintOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "bgGlassTintOpacity", fallback: 0.03)))
        """

        let menuBarPayload = MenuBarIconDebugSettings.copyPayload(defaults: defaults)
        let browserDevToolsPayload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: defaults)

        return """
        # Sidebar Debug
        \(sidebarPayload)

        # Background Debug
        \(backgroundPayload)

        # Menu Bar Extra Debug
        \(menuBarPayload)

        # Browser DevTools Button
        \(browserDevToolsPayload)
        """
    }

    private static func stringValue(_ defaults: UserDefaults, key: String, fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    private static func doubleValue(_ defaults: UserDefaults, key: String, fallback: Double) -> Double {
        if let value = defaults.object(forKey: key) as? NSNumber {
            return value.doubleValue
        }
        if let text = defaults.string(forKey: key), let parsed = Double(text) {
            return parsed
        }
        return fallback
    }

    private static func boolValue(_ defaults: UserDefaults, key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}

private final class DebugWindowControlsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = DebugWindowControlsWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Debug Window Controls"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.debugWindowControls")
        window.center()
        window.contentView = NSHostingView(rootView: DebugWindowControlsView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DebugWindowControlsView: View {
    @AppStorage(ShortcutHintDebugSettings.titlebarHintXKey) private var titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
    @AppStorage(ShortcutHintDebugSettings.titlebarHintYKey) private var titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
    @AppStorage(ShortcutHintDebugSettings.paneHintXKey) private var paneShortcutHintXOffset = ShortcutHintDebugSettings.defaultPaneHintX
    @AppStorage(ShortcutHintDebugSettings.paneHintYKey) private var paneShortcutHintYOffset = ShortcutHintDebugSettings.defaultPaneHintY
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(SidebarActiveWorkspaceIndicatorSettings.styleKey)
    private var sidebarActiveWorkspaceIndicatorStyle = SidebarActiveWorkspaceIndicatorSettings.defaultStyle.rawValue
    @AppStorage("debugTitlebarLeadingExtra") private var titlebarLeadingExtra: Double = 0
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconNameKey) private var browserDevToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconColorKey) private var browserDevToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue

    private var selectedDevToolsIconOption: BrowserDevToolsIconOption {
        BrowserDevToolsIconOption(rawValue: browserDevToolsIconNameRaw) ?? BrowserDevToolsButtonDebugSettings.defaultIcon
    }

    private var selectedDevToolsColorOption: BrowserDevToolsIconColorOption {
        BrowserDevToolsIconColorOption(rawValue: browserDevToolsIconColorRaw) ?? BrowserDevToolsButtonDebugSettings.defaultColor
    }

    private var selectedSidebarActiveWorkspaceIndicatorStyle: SidebarActiveWorkspaceIndicatorStyle {
        SidebarActiveWorkspaceIndicatorSettings.resolvedStyle(rawValue: sidebarActiveWorkspaceIndicatorStyle)
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarActiveWorkspaceIndicatorStyle.rawValue },
            set: { sidebarActiveWorkspaceIndicatorStyle = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Debug Window Controls")
                    .font(.headline)

                GroupBox("Open") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Browser Import Hint Debug…") {
                            BrowserImportHintDebugWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.browserProfilePopoverDebug",
                                defaultValue: "Browser Profile Popover Debug…"
                            )
                        ) {
                            BrowserProfilePopoverDebugWindowController.shared.show()
                        }
                        Button("Settings/About Titlebar Debug…") {
                            SettingsAboutTitlebarDebugWindowController.shared.show()
                        }
                        Button("Sidebar Debug…") {
                            SidebarDebugWindowController.shared.show()
                        }
                        Button("Background Debug…") {
                            BackgroundDebugWindowController.shared.show()
                        }
                        Button("Menu Bar Extra Debug…") {
                            MenuBarExtraDebugWindowController.shared.show()
                        }
                        Button("Open All Debug Windows") {
                            BrowserImportHintDebugWindowController.shared.show()
                            BrowserProfilePopoverDebugWindowController.shared.show()
                            SettingsAboutTitlebarDebugWindowController.shared.show()
                            SidebarDebugWindowController.shared.show()
                            BackgroundDebugWindowController.shared.show()
                            MenuBarExtraDebugWindowController.shared.show()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                GroupBox("Shortcut Hints") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Always show shortcut hints", isOn: $alwaysShowShortcutHints)

                        hintOffsetSection(
                            "Titlebar Buttons",
                            x: $titlebarShortcutHintXOffset,
                            y: $titlebarShortcutHintYOffset
                        )

                        hintOffsetSection(
                            "Pane Ctrl/Cmd+1…9",
                            x: $paneShortcutHintXOffset,
                            y: $paneShortcutHintYOffset
                        )

                        HStack(spacing: 12) {
                            Button("Reset Hints") {
                                resetShortcutHintOffsets()
                            }
                            Button("Copy Hint Config") {
                                copyShortcutHintConfig()
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Active Workspace Indicator") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Style", selection: sidebarIndicatorStyleSelection) {
                            ForEach(SidebarActiveWorkspaceIndicatorStyle.allCases) { style in
                                Text(style.displayName).tag(style.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        Button("Reset Indicator Style") {
                            sidebarActiveWorkspaceIndicatorStyle = SidebarActiveWorkspaceIndicatorSettings.defaultStyle.rawValue
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Titlebar Spacing") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Leading extra")
                            Slider(value: $titlebarLeadingExtra, in: 0...40)
                            Text(String(format: "%.0f", titlebarLeadingExtra))
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 30, alignment: .trailing)
                        }
                        Button("Reset (0)") {
                            titlebarLeadingExtra = 0
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Browser DevTools Button") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Icon")
                            Picker("Icon", selection: $browserDevToolsIconNameRaw) {
                                ForEach(BrowserDevToolsIconOption.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text("Color")
                            Picker("Color", selection: $browserDevToolsIconColorRaw) {
                                ForEach(BrowserDevToolsIconColorOption.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text("Preview")
                            Spacer()
                            Image(systemName: selectedDevToolsIconOption.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(selectedDevToolsColorOption.color)
                        }

                        HStack(spacing: 12) {
                            Button("Reset Button") {
                                resetBrowserDevToolsButton()
                            }
                            Button("Copy Button Config") {
                                copyBrowserDevToolsButtonConfig()
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Copy") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Copy All Debug Config") {
                            DebugWindowConfigSnapshot.copyCombinedToPasteboard()
                        }
                        Text("Copies sidebar, background, menu bar, and browser devtools settings as one payload.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func hintOffsetSection(_ title: String, x: Binding<Double>, y: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            sliderRow("X", value: x)
            sliderRow("Y", value: y)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Slider(value: value, in: ShortcutHintDebugSettings.offsetRange)
            Text(String(format: "%.1f", ShortcutHintDebugSettings.clamped(value.wrappedValue)))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func resetShortcutHintOffsets() {
        titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
        titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
        paneShortcutHintXOffset = ShortcutHintDebugSettings.defaultPaneHintX
        paneShortcutHintYOffset = ShortcutHintDebugSettings.defaultPaneHintY
        alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    }

    private func copyShortcutHintConfig() {
        let payload = """
        shortcutHintTitlebarXOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset)))
        shortcutHintTitlebarYOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(titlebarShortcutHintYOffset)))
        shortcutHintPaneTabXOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(paneShortcutHintXOffset)))
        shortcutHintPaneTabYOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(paneShortcutHintYOffset)))
        shortcutHintAlwaysShow=\(alwaysShowShortcutHints)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    private func resetBrowserDevToolsButton() {
        browserDevToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
        browserDevToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue
    }

    private func copyBrowserDevToolsButtonConfig() {
        let payload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: .standard)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
}

private final class BrowserImportHintDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = BrowserImportHintDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Browser Import Hint Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserImportHintDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BrowserImportHintDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class BrowserProfilePopoverDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = BrowserProfilePopoverDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.windows.browserProfilePopover.title",
            defaultValue: "Browser Profile Popover Debug"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserProfilePopoverDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BrowserProfilePopoverDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct BrowserProfilePopoverDebugView: View {
    @AppStorage(BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
    private var horizontalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
    @AppStorage(BrowserProfilePopoverDebugSettings.verticalPaddingKey)
    private var verticalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultVerticalPadding

    private var horizontalPaddingBinding: Binding<Double> {
        Binding(
            get: { BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding(horizontalPaddingRaw) },
            set: { horizontalPaddingRaw = BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding($0) }
        )
    }

    private var verticalPaddingBinding: Binding<Double> {
        Binding(
            get: { BrowserProfilePopoverDebugSettings.resolvedVerticalPadding(verticalPaddingRaw) },
            set: { verticalPaddingRaw = BrowserProfilePopoverDebugSettings.resolvedVerticalPadding($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    String(
                        localized: "debug.browserProfilePopover.heading",
                        defaultValue: "Browser Profile Popover"
                    )
                )
                .font(.headline)

                Text(
                    String(
                        localized: "debug.browserProfilePopover.note",
                        defaultValue: "Tune the profile popover padding live while comparing it against the browser toolbar menu."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                GroupBox(
                    String(
                        localized: "debug.browserProfilePopover.group.padding",
                        defaultValue: "Padding"
                    )
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow(
                            String(
                                localized: "debug.browserProfilePopover.label.horizontal",
                                defaultValue: "Horizontal"
                            ),
                            value: horizontalPaddingBinding,
                            range: BrowserProfilePopoverDebugSettings.horizontalPaddingRange
                        )
                        sliderRow(
                            String(
                                localized: "debug.browserProfilePopover.label.vertical",
                                defaultValue: "Vertical"
                            ),
                            value: verticalPaddingBinding,
                            range: BrowserProfilePopoverDebugSettings.verticalPaddingRange
                        )
                    }
                    .padding(.top, 2)
                }

                GroupBox(
                    String(
                        localized: "debug.browserProfilePopover.group.preview",
                        defaultValue: "Preview"
                    )
                ) {
                    profilePopoverPreview
                        .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button(
                        String(
                            localized: "debug.browserProfilePopover.reset",
                            defaultValue: "Reset"
                        )
                    ) {
                        horizontalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
                        verticalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultVerticalPadding
                    }
                }

                Text(
                    String(
                        localized: "debug.browserProfilePopover.liveNote",
                        defaultValue: "Changes apply live to the browser profile popover."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var profilePopoverPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.profile.menu.title", defaultValue: "Profiles"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, alignment: .center)
                    Text(String(localized: "browser.profile.default", defaultValue: "Default"))
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                )
            }

            Divider()

            Text(String(localized: "browser.profile.new", defaultValue: "New Profile..."))
                .font(.system(size: 12))

            Text(String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"))
                .font(.system(size: 12))
        }
        .padding(.horizontal, BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding(horizontalPaddingRaw))
        .padding(.vertical, BrowserProfilePopoverDebugSettings.resolvedVerticalPadding(verticalPaddingRaw))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                )
        )
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Slider(value: value, in: range, step: 1)
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
    }
}

private struct BrowserImportHintDebugView: View {
    @AppStorage(BrowserImportHintSettings.variantKey)
    private var variantRaw = BrowserImportHintSettings.defaultVariant.rawValue
    @AppStorage(BrowserImportHintSettings.showOnBlankPanelsKey)
    private var showOnBlankPanels = BrowserImportHintSettings.defaultShowOnBlankPanels
    @AppStorage(BrowserImportHintSettings.dismissedKey)
    private var isDismissed = BrowserImportHintSettings.defaultDismissed

    private var selectedVariant: BrowserImportHintVariant {
        BrowserImportHintSettings.variant(for: variantRaw)
    }

    private var variantSelection: Binding<String> {
        Binding(
            get: { selectedVariant.rawValue },
            set: { variantRaw = BrowserImportHintSettings.variant(for: $0).rawValue }
        )
    }

    private var showOnBlankPanelsBinding: Binding<Bool> {
        Binding(
            get: { showOnBlankPanels },
            set: { newValue in
                showOnBlankPanels = newValue
                if newValue {
                    isDismissed = false
                }
            }
        )
    }

    private var presentation: BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            variant: selectedVariant,
            showOnBlankPanels: showOnBlankPanels,
            isDismissed: isDismissed
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Browser Import Hint")
                    .font(.headline)

                Text("Try lighter blank-tab import surfaces and dismissal states without touching the permanent Browser settings home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox("Variant") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Blank Tab Style", selection: variantSelection) {
                            ForEach(BrowserImportHintVariant.allCases) { variant in
                                Text(title(for: variant)).tag(variant.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(description(for: selectedVariant))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }

                GroupBox("State") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show on blank browser tabs", isOn: showOnBlankPanelsBinding)
                        Toggle("Pretend the user dismissed it", isOn: $isDismissed)

                        Text("Current blank-tab placement: \(placementTitle(presentation.blankPanelPlacement))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Settings status: \(settingsStatusTitle(presentation.settingsStatus))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Quick Actions") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button("Open Browser Settings") {
                                AppDelegate.presentPreferencesWindow(navigationTarget: .browser)
                            }
                            Button("Open Import Dialog") {
                                DispatchQueue.main.async {
                                    BrowserDataImportCoordinator.shared.presentImportDialog()
                                }
                            }
                        }

                        Button("Reset Hint Debug State") {
                            BrowserImportHintSettings.reset()
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Ideas") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Inline strip: default candidate, visible but quieter than the old floating card.")
                        Text("Floating card: strongest nudge, useful when we want more explanation.")
                        Text("Toolbar chip: most subtle, best when the hint should stay out of the content area.")
                        Text("Settings only: no in-browser nudge, Browser settings becomes the only permanent home.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func title(for variant: BrowserImportHintVariant) -> String {
        switch variant {
        case .inlineStrip:
            return "Inline Strip"
        case .floatingCard:
            return "Floating Card"
        case .toolbarChip:
            return "Toolbar Chip"
        case .settingsOnly:
            return "Settings Only"
        }
    }

    private func description(for variant: BrowserImportHintVariant) -> String {
        switch variant {
        case .inlineStrip:
            return "Shows a thin hint bar at the top of blank browser tabs."
        case .floatingCard:
            return "Shows the fuller callout card inside blank browser tabs."
        case .toolbarChip:
            return "Moves the hint into a small toolbar chip beside the browser controls."
        case .settingsOnly:
            return "Hides the blank-tab hint and leaves Browser settings as the only home."
        }
    }

    private func placementTitle(_ placement: BrowserImportHintBlankPanelPlacement) -> String {
        switch placement {
        case .hidden:
            return "Hidden"
        case .inlineStrip:
            return "Inline Strip"
        case .floatingCard:
            return "Floating Card"
        case .toolbarChip:
            return "Toolbar Chip"
        }
    }

    private func settingsStatusTitle(_ status: BrowserImportHintSettingsStatus) -> String {
        switch status {
        case .visible:
            return "Visible"
        case .hidden:
            return "Hidden"
        case .settingsOnly:
            return "Settings Only"
        }
    }
}

private final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.about")
        window.center()
        window.contentView = NSHostingView(rootView: AboutPanelView())
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .about)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .about)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

private final class AcknowledgmentsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AcknowledgmentsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "about.licenses.windowTitle", defaultValue: "Third-Party Licenses")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.licenses")
        window.center()
        window.contentView = NSHostingView(rootView: AcknowledgmentsView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
    }
}

private struct AcknowledgmentsView: View {
    private let content: String = {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "md"),
           let text = try? String(contentsOf: url) {
            return text
        }
        return String(localized: "about.licenses.notFound", defaultValue: "Licenses file not found.")
    }()

    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var pendingFocusRestoreWorkItems: [DispatchWorkItem] = []
    private var focusRestoreGeneration = 0

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.settings")
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView())
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .settings)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(navigationTarget: SettingsNavigationTarget? = nil) {
        guard let window else { return }
#if DEBUG
        dlog("settings.window.show requested isVisible=\(window.isVisible ? 1 : 0) isKey=\(window.isKeyWindow ? 1 : 0)")
#endif
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .settings)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        if let navigationTarget {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                SettingsNavigationRequest.post(navigationTarget)
            }
        }
#if DEBUG
        dlog("settings.window.show completed isVisible=\(window.isVisible ? 1 : 0) isKey=\(window.isKeyWindow ? 1 : 0)")
#endif
    }

    func preserveFocusAfterPreferenceMutation() {
        guard let window, window.isVisible else { return }
        cancelPendingFocusRestore()
        focusRestoreGeneration += 1
        let generation = focusRestoreGeneration
        writeFocusDiagnosticsIfNeeded(stage: "requested")
        scheduleFocusRestore(
            for: window,
            generation: generation,
            delays: [0, 0.04, 0.12, 0.24, 0.4, 0.7]
        )
    }

    func windowWillClose(_ notification: Notification) {
        cancelPendingFocusRestore()
        writeFocusDiagnosticsIfNeeded(stage: "windowWillClose")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        writeFocusDiagnosticsIfNeeded(stage: "didBecomeKey")
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window else { return }
        writeFocusDiagnosticsIfNeeded(stage: "didResignKey")
        guard focusRestoreGeneration > 0 else { return }
        scheduleFocusRestore(
            for: window,
            generation: focusRestoreGeneration,
            delays: [0, 0.03, 0.1]
        )
    }

    private func scheduleFocusRestore(
        for window: NSWindow,
        generation: Int,
        delays: [TimeInterval]
    ) {
        for (index, delay) in delays.enumerated() {
            let isLastAttempt = index == delays.count - 1
            let workItem = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window, window.isVisible else { return }
                guard self.focusRestoreGeneration == generation else { return }
                self.writeFocusDiagnosticsIfNeeded(stage: "restoreAttempt.\(index)")
                if !window.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    window.orderFrontRegardless()
                    window.makeKeyAndOrderFront(nil)
                    self.writeFocusDiagnosticsIfNeeded(stage: "restoreApplied.\(index)")
                }
                if isLastAttempt, self.focusRestoreGeneration == generation {
                    self.focusRestoreGeneration = 0
                }
            }
            pendingFocusRestoreWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func cancelPendingFocusRestore() {
        pendingFocusRestoreWorkItems.forEach { $0.cancel() }
        pendingFocusRestoreWorkItems.removeAll()
        focusRestoreGeneration = 0
    }

    private func writeFocusDiagnosticsIfNeeded(stage: String) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_DIAGNOSTICS_PATH"], !path.isEmpty else { return }

        var payload = loadFocusDiagnostics(at: path)
        payload["focusStage"] = stage
        payload["keyWindowIdentifier"] = NSApp.keyWindow?.identifier?.rawValue ?? ""
        payload["mainWindowIdentifier"] = NSApp.mainWindow?.identifier?.rawValue ?? ""
        payload["settingsWindowIsKey"] = (window?.isKeyWindow ?? false) ? "1" : "0"

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadFocusDiagnostics(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
}

enum SettingsNavigationTarget: String {
    case browser
    case browserImport
    case textBoxInput
    case keyboardShortcuts
    /// The Agents & Automation page's default-agent / Saved Configs section
    /// (C11-182), the anchor the agent-config editor navigates to.
    case agents
    /// c11h: the Herder Topography page (the map of machines and their
    /// herder cores), where Add Machine lives. The panel bar's herder-core
    /// popover opens it.
    case machines
}

enum SettingsNavigationRequest {
    static let notificationName = Notification.Name("cmux.settings.navigate")
    private static let targetKey = "target"

    static func post(_ target: SettingsNavigationTarget) {
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [targetKey: target.rawValue]
        )
    }

    static func target(from notification: Notification) -> SettingsNavigationTarget? {
        guard let rawValue = notification.userInfo?[targetKey] as? String else { return nil }
        return SettingsNavigationTarget(rawValue: rawValue)
    }
}

private final class SidebarDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SidebarDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidebar Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.sidebarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SidebarDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AboutPanelView: View {
    @Environment(\.openURL) private var openURL

    private let forkURL = URL(string: "https://github.com/Stage-11-Agentics/c11")
    private let docsURL = URL(string: "https://github.com/Stage-11-Agentics/c11")

    private var version: String? { C11BuildIdentity(info: Bundle.main.infoDictionary ?? [:]).versionLine }
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? {
        C11BuildIdentity.resolveCommit(
            info: Bundle.main.infoDictionary ?? [:],
            environment: ProcessInfo.processInfo.environment
        )
    }
    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    var body: some View {
        VStack(alignment: .center) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text(String(localized: "about.appName", defaultValue: "c11"))
                        .bold()
                        .font(.title)
                    Text(String(localized: "about.forkAttribution", defaultValue: "A Stage 11 Agentics fork of cmux by manaflow-ai"))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.85)
                    Text(String(localized: "about.description", defaultValue: "terminal command center for the operator:agent pair.\nmany panels. one workspace. one field of view."))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    if let version {
                        AboutPropertyRow(label: String(localized: "about.version", defaultValue: "Version"), text: version)
                    }
                    if let build {
                        AboutPropertyRow(label: String(localized: "about.build", defaultValue: "Build"), text: build)
                    }
                    let commitText = commit ?? "—"
                    let commitURL = commit.flatMap { hash in
                        URL(string: "https://github.com/Stage-11-Agentics/c11/commit/\(hash)")
                    }
                    AboutPropertyRow(label: String(localized: "about.commit", defaultValue: "Commit"), text: commitText, url: commitURL)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = docsURL {
                        Button(String(localized: "about.docs", defaultValue: "Docs")) {
                            openURL(url)
                        }
                    }
                    if let url = forkURL {
                        Button(String(localized: "about.github", defaultValue: "GitHub")) {
                            openURL(url)
                        }
                    }
                    Button(String(localized: "about.licenses", defaultValue: "Licenses")) {
                        AcknowledgmentsWindowController.shared.show()
                    }
                }

                if let copy = copyright, !copy.isEmpty {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 280)
        .background(AboutVisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }
}

private struct SidebarDebugView: View {
    @AppStorage("sidebarPreset") private var sidebarPreset = SidebarPresetOption.nativeSidebar.rawValue
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarState") private var sidebarState = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0
    @AppStorage(SidebarBranchLayoutSettings.key) private var sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
    @AppStorage(ShortcutHintDebugSettings.titlebarHintXKey) private var titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
    @AppStorage(ShortcutHintDebugSettings.titlebarHintYKey) private var titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
    @AppStorage(ShortcutHintDebugSettings.paneHintXKey) private var paneShortcutHintXOffset = ShortcutHintDebugSettings.defaultPaneHintX
    @AppStorage(ShortcutHintDebugSettings.paneHintYKey) private var paneShortcutHintYOffset = ShortcutHintDebugSettings.defaultPaneHintY
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
    @AppStorage(SidebarActiveWorkspaceIndicatorSettings.styleKey)
    private var sidebarActiveWorkspaceIndicatorStyle = SidebarActiveWorkspaceIndicatorSettings.defaultStyle.rawValue

    private var selectedSidebarIndicatorStyle: SidebarActiveWorkspaceIndicatorStyle {
        SidebarActiveWorkspaceIndicatorSettings.resolvedStyle(rawValue: sidebarActiveWorkspaceIndicatorStyle)
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarIndicatorStyle.rawValue },
            set: { sidebarActiveWorkspaceIndicatorStyle = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Sidebar Appearance")
                    .font(.headline)

                GroupBox("Presets") {
                    Picker("Preset", selection: $sidebarPreset) {
                        ForEach(SidebarPresetOption.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .onChange(of: sidebarPreset) { _ in
                        applyPreset()
                    }
                    .padding(.top, 2)
                }

                GroupBox("Blur") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Material", selection: $sidebarMaterial) {
                            ForEach(SidebarMaterialOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        Picker("Blending", selection: $sidebarBlendMode) {
                            ForEach(SidebarBlendModeOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        Picker("State", selection: $sidebarState) {
                            ForEach(SidebarStateOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        HStack(spacing: 8) {
                            Text("Strength")
                            Slider(value: $sidebarBlurOpacity, in: 0...1)
                            Text(String(format: "%.0f%%", sidebarBlurOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Tint") {
                    VStack(alignment: .leading, spacing: 8) {
                        ColorPicker("Tint Color", selection: tintColorBinding, supportsOpacity: false)

                        HStack(spacing: 8) {
                            Text("Opacity")
                            Slider(value: $sidebarTintOpacity, in: 0...0.7)
                            Text(String(format: "%.0f%%", sidebarTintOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Shape") {
                    HStack(spacing: 8) {
                        Text("Corner Radius")
                        Slider(value: $sidebarCornerRadius, in: 0...20)
                        Text(String(format: "%.0f", sidebarCornerRadius))
                            .font(.caption)
                            .frame(width: 32, alignment: .trailing)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Shortcut Hints") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Always show shortcut hints", isOn: $alwaysShowShortcutHints)

                        hintOffsetSection(
                            "Titlebar Buttons",
                            x: $titlebarShortcutHintXOffset,
                            y: $titlebarShortcutHintYOffset
                        )

                        hintOffsetSection(
                            "Pane Ctrl/Cmd+1…9",
                            x: $paneShortcutHintXOffset,
                            y: $paneShortcutHintYOffset
                        )
                    }
                    .padding(.top, 2)
                }

                GroupBox("Active Workspace Indicator") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Style", selection: sidebarIndicatorStyleSelection) {
                            ForEach(SidebarActiveWorkspaceIndicatorStyle.allCases) { style in
                                Text(style.displayName).tag(style.rawValue)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Workspace Metadata") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Render branch list vertically", isOn: $sidebarBranchVerticalLayout)
                        Text("When enabled, each branch appears on its own line in the sidebar.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button("Reset Tint") {
                        sidebarTintOpacity = 0.62
                        sidebarTintHex = SidebarTintDefaults.hex
                        sidebarTintHexLight = nil
                        sidebarTintHexDark = nil
                    }
                    Button("Reset Blur") {
                        sidebarMaterial = SidebarMaterialOption.hudWindow.rawValue
                        sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
                        sidebarState = SidebarStateOption.active.rawValue
                        sidebarBlurOpacity = 0.98
                    }
                    Button("Reset Shape") {
                        sidebarCornerRadius = 0.0
                    }
                    Button("Reset Hints") {
                        resetShortcutHintOffsets()
                    }
                    Button("Reset Active Indicator") {
                        sidebarActiveWorkspaceIndicatorStyle = SidebarActiveWorkspaceIndicatorSettings.defaultStyle.rawValue
                    }
                }

                Button("Copy Config") {
                    copySidebarConfig()
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var tintColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(hex: sidebarTintHex) ?? .black)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                sidebarTintHex = nsColor.hexString()
            }
        )
    }

    private func hintOffsetSection(_ title: String, x: Binding<Double>, y: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            sliderRow("X", value: x)
            sliderRow("Y", value: y)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Slider(value: value, in: ShortcutHintDebugSettings.offsetRange)
            Text(String(format: "%.1f", ShortcutHintDebugSettings.clamped(value.wrappedValue)))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func resetShortcutHintOffsets() {
        titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
        titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
        paneShortcutHintXOffset = ShortcutHintDebugSettings.defaultPaneHintX
        paneShortcutHintYOffset = ShortcutHintDebugSettings.defaultPaneHintY
        alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    }

    private func copySidebarConfig() {
        let payload = """
        sidebarPreset=\(sidebarPreset)
        sidebarMaterial=\(sidebarMaterial)
        sidebarBlendMode=\(sidebarBlendMode)
        sidebarState=\(sidebarState)
        sidebarBlurOpacity=\(String(format: "%.2f", sidebarBlurOpacity))
        sidebarTintHex=\(sidebarTintHex)
        sidebarTintHexLight=\(sidebarTintHexLight ?? "(nil)")
        sidebarTintHexDark=\(sidebarTintHexDark ?? "(nil)")
        sidebarTintOpacity=\(String(format: "%.2f", sidebarTintOpacity))
        sidebarCornerRadius=\(String(format: "%.1f", sidebarCornerRadius))
        sidebarBranchVerticalLayout=\(sidebarBranchVerticalLayout)
        sidebarActiveTabIndicatorStyle=\(sidebarActiveWorkspaceIndicatorStyle)
        sidebarDevBuildBannerVisible=\(showSidebarDevBuildBanner)
        shortcutHintTitlebarXOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset)))
        shortcutHintTitlebarYOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(titlebarShortcutHintYOffset)))
        shortcutHintPaneTabXOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(paneShortcutHintXOffset)))
        shortcutHintPaneTabYOffset=\(String(format: "%.1f", ShortcutHintDebugSettings.clamped(paneShortcutHintYOffset)))
        shortcutHintAlwaysShow=\(alwaysShowShortcutHints)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    private func applyPreset() {
        guard let preset = SidebarPresetOption(rawValue: sidebarPreset) else { return }
        sidebarMaterial = preset.material.rawValue
        sidebarBlendMode = preset.blendMode.rawValue
        sidebarState = preset.state.rawValue
        sidebarTintHex = preset.tintHex
        sidebarTintOpacity = preset.tintOpacity
        sidebarCornerRadius = preset.cornerRadius
        sidebarBlurOpacity = preset.blurOpacity
        sidebarTintHexLight = nil
        sidebarTintHexDark = nil
    }
}

// MARK: - Menu Bar Extra Debug Window

private final class MenuBarExtraDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MenuBarExtraDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 430),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Menu Bar Extra Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.menubarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: MenuBarExtraDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct MenuBarExtraDebugView: View {
    @AppStorage(MenuBarIconDebugSettings.previewEnabledKey) private var previewEnabled = false
    @AppStorage(MenuBarIconDebugSettings.previewCountKey) private var previewCount = 1
    @AppStorage(MenuBarIconDebugSettings.badgeRectXKey) private var badgeRectX = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.x)
    @AppStorage(MenuBarIconDebugSettings.badgeRectYKey) private var badgeRectY = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.y)
    @AppStorage(MenuBarIconDebugSettings.badgeRectWidthKey) private var badgeRectWidth = Double(MenuBarIconDebugSettings.defaultBadgeRect.width)
    @AppStorage(MenuBarIconDebugSettings.badgeRectHeightKey) private var badgeRectHeight = Double(MenuBarIconDebugSettings.defaultBadgeRect.height)
    @AppStorage(MenuBarIconDebugSettings.singleDigitFontSizeKey) private var singleDigitFontSize = Double(MenuBarIconDebugSettings.defaultSingleDigitFontSize)
    @AppStorage(MenuBarIconDebugSettings.multiDigitFontSizeKey) private var multiDigitFontSize = Double(MenuBarIconDebugSettings.defaultMultiDigitFontSize)
    @AppStorage(MenuBarIconDebugSettings.singleDigitYOffsetKey) private var singleDigitYOffset = Double(MenuBarIconDebugSettings.defaultSingleDigitYOffset)
    @AppStorage(MenuBarIconDebugSettings.multiDigitYOffsetKey) private var multiDigitYOffset = Double(MenuBarIconDebugSettings.defaultMultiDigitYOffset)
    @AppStorage(MenuBarIconDebugSettings.singleDigitXAdjustKey) private var singleDigitXAdjust = Double(MenuBarIconDebugSettings.defaultSingleDigitXAdjust)
    @AppStorage(MenuBarIconDebugSettings.multiDigitXAdjustKey) private var multiDigitXAdjust = Double(MenuBarIconDebugSettings.defaultMultiDigitXAdjust)
    @AppStorage(MenuBarIconDebugSettings.textRectWidthAdjustKey) private var textRectWidthAdjust = Double(MenuBarIconDebugSettings.defaultTextRectWidthAdjust)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Menu Bar Extra Icon")
                    .font(.headline)

                GroupBox("Preview Count") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Override unread count", isOn: $previewEnabled)

                        Stepper(value: $previewCount, in: 0...99) {
                            HStack {
                                Text("Unread Count")
                                Spacer()
                                Text("\(previewCount)")
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                        }
                        .disabled(!previewEnabled)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Badge Rect") {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow("X", value: $badgeRectX, range: 0...20, format: "%.2f")
                        sliderRow("Y", value: $badgeRectY, range: 0...20, format: "%.2f")
                        sliderRow("Width", value: $badgeRectWidth, range: 4...14, format: "%.2f")
                        sliderRow("Height", value: $badgeRectHeight, range: 4...14, format: "%.2f")
                    }
                    .padding(.top, 2)
                }

                GroupBox("Badge Text") {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow("1-digit size", value: $singleDigitFontSize, range: 6...14, format: "%.2f")
                        sliderRow("2-digit size", value: $multiDigitFontSize, range: 6...14, format: "%.2f")
                        sliderRow("1-digit X", value: $singleDigitXAdjust, range: -4...4, format: "%.2f")
                        sliderRow("2-digit X", value: $multiDigitXAdjust, range: -4...4, format: "%.2f")
                        sliderRow("1-digit Y", value: $singleDigitYOffset, range: -3...4, format: "%.2f")
                        sliderRow("2-digit Y", value: $multiDigitYOffset, range: -3...4, format: "%.2f")
                        sliderRow("Text width adjust", value: $textRectWidthAdjust, range: -3...5, format: "%.2f")
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button("Reset") {
                        previewEnabled = false
                        previewCount = 1
                        badgeRectX = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.x)
                        badgeRectY = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.y)
                        badgeRectWidth = Double(MenuBarIconDebugSettings.defaultBadgeRect.width)
                        badgeRectHeight = Double(MenuBarIconDebugSettings.defaultBadgeRect.height)
                        singleDigitFontSize = Double(MenuBarIconDebugSettings.defaultSingleDigitFontSize)
                        multiDigitFontSize = Double(MenuBarIconDebugSettings.defaultMultiDigitFontSize)
                        singleDigitYOffset = Double(MenuBarIconDebugSettings.defaultSingleDigitYOffset)
                        multiDigitYOffset = Double(MenuBarIconDebugSettings.defaultMultiDigitYOffset)
                        singleDigitXAdjust = Double(MenuBarIconDebugSettings.defaultSingleDigitXAdjust)
                        multiDigitXAdjust = Double(MenuBarIconDebugSettings.defaultMultiDigitXAdjust)
                        textRectWidthAdjust = Double(MenuBarIconDebugSettings.defaultTextRectWidthAdjust)
                        applyLiveUpdate()
                    }

                    Button("Copy Config") {
                        let payload = MenuBarIconDebugSettings.copyPayload()
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(payload, forType: .string)
                    }
                }

                Text("Tip: enable override count, then tune until the menu bar icon looks right.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { applyLiveUpdate() }
        .onChange(of: previewEnabled) { _ in applyLiveUpdate() }
        .onChange(of: previewCount) { _ in applyLiveUpdate() }
        .onChange(of: badgeRectX) { _ in applyLiveUpdate() }
        .onChange(of: badgeRectY) { _ in applyLiveUpdate() }
        .onChange(of: badgeRectWidth) { _ in applyLiveUpdate() }
        .onChange(of: badgeRectHeight) { _ in applyLiveUpdate() }
        .onChange(of: singleDigitFontSize) { _ in applyLiveUpdate() }
        .onChange(of: multiDigitFontSize) { _ in applyLiveUpdate() }
        .onChange(of: singleDigitXAdjust) { _ in applyLiveUpdate() }
        .onChange(of: multiDigitXAdjust) { _ in applyLiveUpdate() }
        .onChange(of: singleDigitYOffset) { _ in applyLiveUpdate() }
        .onChange(of: multiDigitYOffset) { _ in applyLiveUpdate() }
        .onChange(of: textRectWidthAdjust) { _ in applyLiveUpdate() }
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func applyLiveUpdate() {
        AppDelegate.shared?.refreshMenuBarExtraForDebug()
    }
}

// MARK: - Background Debug Window

private final class BackgroundDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = BackgroundDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Background Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.backgroundDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BackgroundDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct BackgroundDebugView: View {
    @AppStorage("bgGlassTintHex") private var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") private var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassMaterial") private var bgGlassMaterial = "hudWindow"
    @AppStorage("bgGlassEnabled") private var bgGlassEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Window Background Glass")
                    .font(.headline)

                GroupBox("Glass Effect") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable Glass Effect", isOn: $bgGlassEnabled)

                        Picker("Material", selection: $bgGlassMaterial) {
                            Text("HUD Window").tag("hudWindow")
                            Text("Under Window").tag("underWindowBackground")
                            Text("Sidebar").tag("sidebar")
                            Text("Menu").tag("menu")
                            Text("Popover").tag("popover")
                        }
                        .disabled(!bgGlassEnabled)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Tint") {
                    VStack(alignment: .leading, spacing: 8) {
                        ColorPicker("Tint Color", selection: tintColorBinding, supportsOpacity: false)
                            .disabled(!bgGlassEnabled)

                        HStack(spacing: 8) {
                            Text("Opacity")
                            Slider(value: $bgGlassTintOpacity, in: 0...0.8)
                                .disabled(!bgGlassEnabled)
                            Text(String(format: "%.0f%%", bgGlassTintOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button("Reset") {
                        bgGlassTintHex = "#000000"
                        bgGlassTintOpacity = 0.03
                        bgGlassMaterial = "hudWindow"
                        bgGlassEnabled = false
                        updateWindowGlassTint()
                    }

                    Button("Copy Config") {
                        copyBgConfig()
                    }
                }

                Text("Tint changes apply live. Enable/disable requires reload.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: bgGlassTintHex) { _ in updateWindowGlassTint() }
        .onChange(of: bgGlassTintOpacity) { _ in updateWindowGlassTint() }
    }

    private func updateWindowGlassTint() {
        let window: NSWindow? = {
            if let key = NSApp.keyWindow,
               let raw = key.identifier?.rawValue,
               raw == "cmux.main" || raw.hasPrefix("cmux.main.") {
                return key
            }
            return NSApp.windows.first(where: {
                guard let raw = $0.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            })
        }()
        guard let window else { return }
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        WindowGlassEffect.updateTint(to: window, color: tintColor)
    }

    private var tintColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(hex: bgGlassTintHex) ?? .black)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                bgGlassTintHex = nsColor.hexString()
            }
        )
    }

    private func copyBgConfig() {
        let payload = """
        bgGlassEnabled=\(bgGlassEnabled)
        bgGlassMaterial=\(bgGlassMaterial)
        bgGlassTintHex=\(bgGlassTintHex)
        bgGlassTintOpacity=\(String(format: "%.2f", bgGlassTintOpacity))
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
}

private struct AboutPropertyRow: View {
    private let label: String
    private let text: String
    private let url: URL?

    init(label: String, text: String, url: URL? = nil) {
        self.label = label
        self.text = text
        self.url = url
    }

    @ViewBuilder private var textView: some View {
        Text(text)
            .frame(width: 140, alignment: .leading)
            .padding(.leading, 2)
            .tint(.secondary)
            .opacity(0.8)
            .monospaced()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 126, alignment: .trailing)
                .padding(.trailing, 2)
            if let url {
                Link(destination: url) {
                    textView
                }
            } else {
                textView
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
    }
}

private struct AboutVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let isEmphasized: Bool

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        isEmphasized: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.isEmphasized = isEmphasized
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = isEmphasized
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffect = NSVisualEffectView()
        visualEffect.autoresizingMask = [.width, .height]
        return visualEffect
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case auto

    var id: String { rawValue }

    static var visibleCases: [AppearanceMode] {
        [.system, .light, .dark]
    }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "appearance.system", defaultValue: "System")
        case .light:
            return String(localized: "appearance.light", defaultValue: "Light")
        case .dark:
            return String(localized: "appearance.dark", defaultValue: "Dark")
        case .auto:
            return String(localized: "appearance.auto", defaultValue: "Auto")
        }
    }
}

enum AppearanceSettings {
    static let appearanceModeKey = "appearanceMode"
    static let defaultMode: AppearanceMode = .system

    static func mode(for rawValue: String?) -> AppearanceMode {
        guard let rawValue, let mode = AppearanceMode(rawValue: rawValue) else {
            return defaultMode
        }
        if mode == .auto {
            return .system
        }
        return mode
    }

    @discardableResult
    static func resolvedMode(defaults: UserDefaults = .standard) -> AppearanceMode {
        let stored = defaults.string(forKey: appearanceModeKey)
        let resolved = mode(for: stored)
        if stored != resolved.rawValue {
            defaults.set(resolved.rawValue, forKey: appearanceModeKey)
        }
        return resolved
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja
    case ko
    case ru
    case uk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "language.system", defaultValue: "System")
        case .en: return "English"
        case .zhHans: return "简体中文 (Chinese Simplified)"
        case .zhHant: return "繁體中文 (Chinese Traditional)"
        case .ja: return "日本語 (Japanese)"
        case .ko: return "한국어 (Korean)"
        case .ru: return "Русский (Russian)"
        case .uk: return "Українська (Ukrainian)"
        }
    }
}

enum LanguageSettings {
    static let languageKey = "appLanguage"
    static let defaultLanguage: AppLanguage = .system

    static func apply(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    static var languageAtLaunch: AppLanguage = {
        let stored = UserDefaults.standard.string(forKey: languageKey)
        guard let stored, let lang = AppLanguage(rawValue: stored) else {
            if stored != nil {
                UserDefaults.standard.removeObject(forKey: languageKey)
            }
            return .system
        }
        return lang
    }()
}

enum QuitWarningSettings {
    static let warnBeforeQuitKey = "warnBeforeQuitShortcut"
    static let defaultWarnBeforeQuit = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: warnBeforeQuitKey) == nil {
            return defaultWarnBeforeQuit
        }
        return defaults.bool(forKey: warnBeforeQuitKey)
    }

}

/// C11H-267: Keep Terminals After Quit. On (the default), quitting detaches
/// terminals and they keep running. Off, an operator's quit ends them and
/// stops this app's own hc cores, as c11 1.x did. An update or settings
/// relaunch, a TERM (the installer's update), a logout or a shutdown never
/// ends them through this switch.
enum QuitTerminalsSettings {
    static let keepTerminalsKey = "c11.quit.keepTerminals"
    static let defaultKeepTerminals = true
    /// The whole stop (ends, then every shard's core). Quit never waits longer.
    static let stopSeconds: TimeInterval = 4

    static func keepsTerminals(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepTerminalsKey) == nil ? defaultKeepTerminals : defaults.bool(forKey: keepTerminalsKey)
    }

    struct TerminationDecision: Equatable {
        let bypassArmed: Bool
        let endsTerminals: Bool
    }

    /// What one quit request does: consumes the relaunch bypass (an update,
    /// a settings relaunch or a clean restart armed it) and decides whether
    /// the terminals end. `applicationShouldTerminate` calls this.
    static func decide(defaults: UserDefaults = .standard, quitReason: OSType?, terminationSignal: Bool,
                       now: Date = Date()) -> TerminationDecision {
        let bypass = QuitConfirmationPolicy.consumeBypass(now: now)
        return TerminationDecision(bypassArmed: bypass, endsTerminals: endsTerminals(
            keepTerminals: keepsTerminals(defaults: defaults), relaunchBypass: bypass,
            quitReason: quitReason, terminationSignal: terminationSignal))
    }

    static func endsTerminals(keepTerminals: Bool, relaunchBypass: Bool, quitReason: OSType?,
                              terminationSignal: Bool) -> Bool {
        if keepTerminals || relaunchBypass || terminationSignal { return false }
        if let quitReason, QuitConfirmationPolicy.systemSessionQuitReasons.contains(quitReason) { return false }
        return true
    }
}

/// Decides whether a quit request asks the operator first. Every quit path
/// (Cmd+Q, the app menu, the Dock, the menu bar extra, AppleScript) arrives at
/// `applicationShouldTerminate`, so the decision is made there once.
enum QuitConfirmationPolicy {
    /// Armed just before a quit that already carries the operator's intent
    /// (an update relaunch, a settings relaunch) so it skips the prompt.
    /// Consumed by the next quit request, and void after `bypassLifetime` so
    /// a relaunch that never quits cannot waive a later operator quit.
    private static var bypassArmedAt: Date?
    static let bypassLifetime: TimeInterval = 10

    /// Apple Event quit reasons macOS attaches for logout, restart and
    /// shutdown. The session snapshot covers these; a prompt would only
    /// stall the system.
    static let systemSessionQuitReasons: Set<OSType> = [
        OSType(kAELogOut),
        OSType(kAEReallyLogOut),
        OSType(kAEShowRestartDialog),
        OSType(kAERestart),
        OSType(kAEShowShutdownDialog),
        OSType(kAEShutDown),
    ]

    static func armBypass(now: Date = Date()) {
        bypassArmedAt = now
    }

    /// C11H-267: a clean restart (`app.restart`) is the operator's relaunch:
    /// no prompt, and terminals survive it whatever Keep Terminals After Quit says.
    static func armForCleanRestart(now: Date = Date()) {
        armBypass(now: now)
    }

    static func consumeBypass(now: Date = Date()) -> Bool {
        defer { bypassArmedAt = nil }
        guard let bypassArmedAt else { return false }
        return now.timeIntervalSince(bypassArmedAt) <= bypassLifetime
    }

    static func shouldConfirm(
        alreadyTerminating: Bool,
        bypassArmed: Bool,
        warnEnabled: Bool,
        quitReason: OSType?
    ) -> Bool {
        if alreadyTerminating || bypassArmed || !warnEnabled { return false }
        if let quitReason, systemSessionQuitReasons.contains(quitReason) { return false }
        return true
    }
}

enum CommandPaletteRenameSelectionSettings {
    static let selectAllOnFocusKey = "commandPalette.renameSelectAllOnFocus"
    static let defaultSelectAllOnFocus = true

    static func selectAllOnFocusEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: selectAllOnFocusKey) == nil {
            return defaultSelectAllOnFocus
        }
        return defaults.bool(forKey: selectAllOnFocusKey)
    }
}

enum CommandPaletteSwitcherSearchSettings {
    static let searchAllSurfacesKey = "commandPalette.switcherSearchAllSurfaces"
    static let defaultSearchAllSurfaces = false

    static func searchAllSurfacesEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: searchAllSurfacesKey) == nil {
            return defaultSearchAllSurfaces
        }
        return defaults.bool(forKey: searchAllSurfacesKey)
    }
}

enum ClaudeCodeIntegrationSettings {
    static let hooksEnabledKey = "claudeCodeHooksEnabled"
    static let defaultHooksEnabled = true

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hooksEnabledKey) == nil {
            return defaultHooksEnabled
        }
        return defaults.bool(forKey: hooksEnabledKey)
    }
}

enum WelcomeSettings {
    static let shownKey = "cmuxWelcomeShown"
    static let spikeURL = "https://stage11.ai"

    static func shouldAutoPresentFirstRunWelcome(qa: QALaunchPolicy, hasShown: Bool) -> Bool {
        !qa.isActive && !hasShown
    }

    /// Turns the freshly-created welcome workspace into a 2x2 quad by performing
    /// programmatic splits on the workspace model. Called once the initial
    /// top-left terminal's Ghostty surface is ready.
    ///
    /// Layout:
    ///   TL: initialPanel (terminal, renders `c11 welcome` ASCII)
    ///   TR: browser → stage11.ai
    ///   BL: markdown → bundled welcome.md
    ///   BR: terminal → starts `claude` if installed, asking permission as normal
    ///   (c11: never skips permissions for a first launch; keep on c11 sync, C11H-130)
    ///
    /// Newly-created terminal panels auto-queue `sendText` before their surfaces
    /// finish initializing and flush on ready, so we can issue commands immediately.
    ///
    // TODO(CMUX-37 Phase 0+): express the quad as a WorkspaceApplyPlan and
    // apply via WorkspaceLayoutExecutor. The current implementation runs on
    // an already-created workspace with a live terminal panel; the executor
    // assumes workspace-creation responsibility. Migration path: extend
    // WorkspaceLayoutExecutor with an `applyToExistingWorkspace(_:workspace:
    // seedPanel:)` overload that skips step 2 and reuses the seed panel.
    @MainActor
    static func performQuadLayout(on workspace: Workspace, initialPanel: TerminalPanel) {
        PanelLineage.shared.inheritingLaunchOrigin(from: initialPanel.id) {
            performQuadLayoutPanels(on: workspace, initialPanel: initialPanel)
        }
    }

    @MainActor
    private static func performQuadLayoutPanels(on workspace: Workspace, initialPanel: TerminalPanel) {
        let initialPanelId = initialPanel.id
        let welcomeMdPath = Bundle.main.url(forResource: "welcome", withExtension: "md")?.path

        let browserPanel = workspace.newBrowserSplit(
            from: initialPanelId,
            orientation: .horizontal,
            insertFirst: false,
            url: URL(string: spikeURL),
            focus: false
        )

        var bottomRightPanel: TerminalPanel?
        if let browserPanel {
            bottomRightPanel = workspace.newTerminalSplit(
                from: browserPanel.id,
                orientation: .vertical,
                insertFirst: false,
                focus: false
            )
        }

        if let welcomeMdPath {
            _ = workspace.newMarkdownSplit(
                from: initialPanelId,
                orientation: .vertical,
                insertFirst: false,
                filePath: welcomeMdPath,
                focus: false
            )
        }

        if let bottomRightPanel {
            // c11h: a friend's first launch starts Claude with its normal permission prompts,
            // never --dangerously-skip-permissions (Atin, 2026-11-03, C11H-130). Keep this line
            // when a c11 sync conflicts here.
            bottomRightPanel.sendText(
                "command -v claude >/dev/null 2>&1 && claude\n"
            )
        }

        initialPanel.sendText("c11 welcome\n")
    }
}

enum DefaultGridSettings {
    static let enabledKey = "cmuxDefaultGridEnabled"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }

    /// Describes a single split operation inside the default-grid build:
    /// which column's current bottom-most panel to split, and in what
    /// direction.
    struct SplitOp: Equatable {
        enum Direction: Equatable {
            /// Split horizontally (side-by-side) to create a new column.
            case horizontalToNewColumn
            /// Split vertically (top-bottom) below the current column tail.
            case verticalDownInColumn
        }

        let column: Int
        let direction: Direction
    }

    /// Pure grid construction schedule for the default 2×2: one horizontal
    /// split to build column 1, then one vertical split per column.
    static func gridSplitOperations() -> [SplitOp] {
        [
            SplitOp(column: 1, direction: .horizontalToNewColumn),
            SplitOp(column: 0, direction: .verticalDownInColumn),
            SplitOp(column: 1, direction: .verticalDownInColumn),
        ]
    }

    /// Auto-spawns a 2×2 terminal grid rooted at `initialPanel`. Silently
    /// truncates the build if any split fails (partial grid is acceptable).
    /// Callers decide when the initial panel's Ghostty surface is ready.
    ///
    // TODO(CMUX-37 Phase 0+): express the 2x2 grid as a WorkspaceApplyPlan
    // driven by DefaultGridSettings.gridSplitOperations(). Gated on the
    // apply-to-existing-workspace overload (same gate as performQuadLayout).
    // The remote-workspace guard below must move into the executor or stay
    // at the call site post-migration.
    @MainActor
    static func performDefaultGrid(
        on workspace: Workspace,
        initialPanel: TerminalPanel
    ) {
        PanelLineage.shared.inheritingLaunchOrigin(from: initialPanel.id) {
            performDefaultGridPanels(on: workspace, initialPanel: initialPanel)
        }
    }

    @MainActor
    private static func performDefaultGridPanels(
        on workspace: Workspace,
        initialPanel: TerminalPanel
    ) {
        // Remote workspaces spawn a fresh SSH session per pane via
        // `remoteTerminalStartupCommand()`. Fanning out sessions on
        // workspace creation is the wrong default; require an explicit split.
        guard !workspace.isRemoteWorkspace else { return }

        // columnTails[col] = the panel currently occupying the bottom of column col.
        // Seeded with the initial panel in column 0; column 1 is populated by
        // the phase-1 horizontal split before any vertical splits run.
        var columnTails: [Int: TerminalPanel] = [0: initialPanel]

        for op in gridSplitOperations() {
            switch op.direction {
            case .horizontalToNewColumn:
                let sourceColumn = op.column - 1
                guard let source = columnTails[sourceColumn] else {
                    #if DEBUG
                    dlog("grid.split.failed col=\(op.column) dir=\(op.direction) reason=missing_source")
                    #endif
                    return
                }
                guard let newPanel = workspace.newTerminalSplit(
                    from: source.id,
                    orientation: .horizontal,
                    insertFirst: false,
                    focus: false
                ) else {
                    #if DEBUG
                    dlog("grid.split.failed col=\(op.column) dir=\(op.direction)")
                    #endif
                    return
                }
                columnTails[op.column] = newPanel

            case .verticalDownInColumn:
                guard let source = columnTails[op.column] else {
                    #if DEBUG
                    dlog("grid.split.failed col=\(op.column) dir=\(op.direction) reason=missing_source")
                    #endif
                    return
                }
                guard let newPanel = workspace.newTerminalSplit(
                    from: source.id,
                    orientation: .vertical,
                    insertFirst: false,
                    focus: false
                ) else {
                    #if DEBUG
                    dlog("grid.split.failed col=\(op.column) dir=\(op.direction)")
                    #endif
                    return
                }
                columnTails[op.column] = newPanel
            }
        }
    }
}

enum TelemetrySettings {
    static let sendAnonymousTelemetryKey = "sendAnonymousTelemetry"
    static let defaultSendAnonymousTelemetry = false

    /// c11 never starts Sentry or PostHog: they carry c11's project keys, and a
    /// private fork must not report there. The stored preference is ignored.
    /// The code paths stay (inherited features) but are unreachable.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        false
    }

    // Freeze telemetry enablement once per launch. Settings changes apply on next restart.
    /// The user's setting as read at launch. The Settings page compares against this.
    static let userEnabledForCurrentLaunch = isEnabled()

    /// Always off in c11, and the log line says why truthfully. `isEnabled` is
    /// false regardless of the user, so passing it to the gate would log
    /// `user_opted_out`, claiming a choice the user never made. The gate is
    /// asked with `userEnabled: true` never; c11's bundle id is not a released
    /// identity, so the reason is the identity, not the user (C11H-183).
    static let launchDecision: TelemetryLaunchDecision = {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return .off(.missingBundleIdentifier)
        }
        return .off(.unreleasedIdentity(bundleIdentifier))
    }()

    /// True only for a released channel with the user's consent. Every
    /// Sentry and PostHog path reads this.
    static let enabledForCurrentLaunch = launchDecision.isEnabled
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    // C11-14: Agents gets its own nav entry, high in the sidebar. The icon
    // mirrors the per-pane "A" button so operators learn the correlation at
    // a glance.
    case agents
    // c11h: where terminals live: each machine's herder core, on one map.
    case herderTopography
    case appearance
    case workspaceSidebar
    case browser
    case notifications
    case input
    case keyboardShortcuts
    case automation
    case dataPrivacy
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return String(localized: "settings.page.general", defaultValue: "General")
        case .agents:
            return String(localized: "settings.page.agents", defaultValue: "Agents")
        case .herderTopography:
            return String(localized: "settings.page.herderTopography", defaultValue: "Herder Topography")
        case .appearance:
            return String(localized: "settings.page.appearance", defaultValue: "Appearance")
        case .workspaceSidebar:
            return String(localized: "settings.page.workspaceSidebar", defaultValue: "Workspace & Sidebar")
        case .browser:
            return String(localized: "settings.page.browser", defaultValue: "Browser")
        case .notifications:
            return String(localized: "settings.page.notifications", defaultValue: "Notifications")
        case .input:
            return String(localized: "settings.page.input", defaultValue: "Input")
        case .keyboardShortcuts:
            return String(localized: "settings.page.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        case .automation:
            return String(localized: "settings.page.automation", defaultValue: "Automation")
        case .dataPrivacy:
            return String(localized: "settings.page.dataPrivacy", defaultValue: "Data & Privacy")
        case .advanced:
            return String(localized: "settings.page.advanced", defaultValue: "Advanced")
        }
    }

    var helperText: String {
        switch self {
        case .general:
            return String(localized: "settings.page.general.helper", defaultValue: "choose the app-level defaults that travel with the room.")
        case .agents:
            return String(localized: "settings.page.agents.helper", defaultValue: "the A button on every area launches an agent. shape what runs and what it knows about c11.")
        case .herderTopography:
            return String(localized: "settings.page.herderTopography.helper", defaultValue: "every machine your terminals live on, and how to add another.")
        case .appearance:
            return String(localized: "settings.page.appearance.helper", defaultValue: "tune the room without touching terminal themes.")
        case .workspaceSidebar:
            return String(localized: "settings.page.workspaceSidebar.helper", defaultValue: "decide how much signal the sidebar carries while agents work.")
        case .browser:
            return String(localized: "settings.page.browser.helper", defaultValue: "choose which web work stays inside c11.")
        case .notifications:
            return String(localized: "settings.page.notifications.helper", defaultValue: "decide what gets to interrupt the operator.")
        case .input:
            return String(localized: "settings.page.input.helper", defaultValue: "shape command input before it reaches a panel.")
        case .keyboardShortcuts:
            return String(localized: "settings.page.keyboardShortcuts.helper", defaultValue: "shape the keys that move through the room.")
        case .automation:
            return String(localized: "settings.page.automation.helper", defaultValue: "let external tools drive c11 through its local socket.")
        case .dataPrivacy:
            return String(localized: "settings.page.dataPrivacy.helper", defaultValue: "clear local traces and choose what leaves the machine.")
        case .advanced:
            return String(localized: "settings.page.advanced.helper", defaultValue: "low-level controls for ports, sockets, and recovery paths.")
        }
    }

    var iconName: String {
        switch self {
        case .general: return "gearshape"
        // C11-14: matches the per-pane "A" button — "A in a circle" SF Symbol.
        // The visual rhyme between the sidebar nav and the in-pane button
        // teaches the operator what the A button is for.
        case .agents: return "a.circle"
        case .herderTopography: return "circle.hexagongrid"
        case .appearance: return "paintpalette"
        case .workspaceSidebar: return "sidebar.left"
        case .browser: return "globe"
        case .notifications: return "bell"
        case .input: return "text.cursor"
        case .keyboardShortcuts: return "keyboard"
        case .automation: return "point.3.connected.trianglepath.dotted"
        case .dataPrivacy: return "lock.shield"
        case .advanced: return "slider.horizontal.3"
        }
    }

    static func page(for target: SettingsNavigationTarget) -> SettingsPage {
        switch target {
        case .browser, .browserImport:
            return .browser
        case .textBoxInput:
            return .input
        case .keyboardShortcuts:
            return .keyboardShortcuts
        case .agents:
            return .agents
        case .machines:
            return .herderTopography
        }
    }
}

private struct ShortcutSettingsGroup: Identifiable {
    let id: String
    let title: String
    let actions: [KeyboardShortcutSettings.Action]
}

struct SettingsView: View {
    private let pickerColumnWidth: CGFloat = 196
    private let notificationSoundControlWidth: CGFloat = 280

    @AppStorage(LanguageSettings.languageKey) private var appLanguage = LanguageSettings.defaultLanguage.rawValue
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(PanelTypeAvailability.internalBrowserEnabledKey)
    private var internalBrowserEnabled = PanelTypeAvailability.defaultEnabled
    @AppStorage(PanelTypeAvailability.markdownPanelsEnabledKey)
    private var markdownSurfacesEnabled = PanelTypeAvailability.defaultEnabled
    @AppStorage(PanelTypeAvailability.markdownSpawnButtonVisibleKey)
    private var markdownSpawnButtonVisible = PanelTypeAvailability.defaultEnabled
    @AppStorage(PanelOrdinalDisplaySettings.showSurfaceIdsInPanelTitlesKey)
    private var showSurfaceIdsInPanelTitles = PanelOrdinalDisplaySettings.defaultShowSurfaceIds
    @AppStorage(MachinePickerSettings.askKey)
    private var askMachineForNewTerminals = MachinePickerSettings.defaultAsk
    @AppStorage(WorkspaceOrdinalDisplaySettings.showWorkspaceIdsKey)
    private var showWorkspaceIdsInSidebar = WorkspaceOrdinalDisplaySettings.defaultShowWorkspaceIds
    @AppStorage(PanelLayoutSettings.modeKey)
    private var panelLayoutMode = PanelLayoutSettings.defaultMode.rawValue
    /// The picker's selection. An outside write can leave the stored value as the
    /// old `tabs` spelling; it resolves to `strip` so a tag always matches.
    private var panelLayoutSelection: Binding<String> {
        Binding(
            get: { PanelLayoutSettings.mode(for: panelLayoutMode).rawValue },
            set: { panelLayoutMode = $0 }
        )
    }
    @AppStorage(ClaudeCodeIntegrationSettings.hooksEnabledKey)
    private var claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
    @AppStorage(TelemetrySettings.sendAnonymousTelemetryKey)
    private var sendAnonymousTelemetry = TelemetrySettings.defaultSendAnonymousTelemetry
    @AppStorage(ActivityHistoryPolicy.analyticsEnabledKey)
    private var recordUsageAnalytics = true
    @AppStorage(ActivityHistoryPolicy.keepTextKey)
    private var keepActivityText = true
    @AppStorage(ActivityHistoryPolicy.retentionDaysKey)
    private var activityRetentionDays = 14
    private var activityRetentionSelection: Binding<Int> {
        Binding(
            get: { [7, 14, 30].contains(activityRetentionDays) ? activityRetentionDays : 14 },
            set: { activityRetentionDays = $0 }
        )
    }
    @AppStorage(C11Identity.portBaseDefaultsKey) private var cmuxPortBase = C11Identity.defaultPortBase
    @AppStorage("cmuxPortRange") private var cmuxPortRange = 10
    @AppStorage(BrowserSearchSettings.searchEngineKey) private var browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettings.searchSuggestionsEnabledKey) private var browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
    @AppStorage(BrowserThemeSettings.modeKey) private var browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
    @AppStorage(BrowserImportHintSettings.variantKey) private var browserImportHintVariantRaw = BrowserImportHintSettings.defaultVariant.rawValue
    @AppStorage(BrowserImportHintSettings.showOnBlankPanelsKey) private var showBrowserImportHintOnBlankPanels = BrowserImportHintSettings.defaultShowOnBlankPanels
    @AppStorage(BrowserImportHintSettings.dismissedKey) private var isBrowserImportHintDismissed = BrowserImportHintSettings.defaultDismissed
    @AppStorage(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey) private var openTerminalLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenTerminalLinksInCmuxBrowser
    @AppStorage(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey)
    private var interceptTerminalOpenCommandInCmuxBrowser = BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInCmuxBrowserValue()
    @AppStorage(BrowserLinkOpenSettings.browserHostWhitelistKey) private var browserHostWhitelist = BrowserLinkOpenSettings.defaultBrowserHostWhitelist
    @AppStorage(BrowserLinkOpenSettings.browserExternalOpenPatternsKey)
    private var browserExternalOpenPatterns = BrowserLinkOpenSettings.defaultBrowserExternalOpenPatterns
    @AppStorage(BrowserExternalSchemeSettings.allowlistKey)
    private var browserExternalSchemeAllowlist = ""
    @AppStorage(BrowserInsecureHTTPSettings.allowlistKey) private var browserInsecureHTTPAllowlist = BrowserInsecureHTTPSettings.defaultAllowlistText
    @AppStorage(NotificationSoundSettings.key) private var notificationSound = NotificationSoundSettings.defaultValue
    // C11H-319: the needs-you sound, apart from the turn-end sound.
    @AppStorage(NotificationSoundChannel.needsYou.defaultsKey)
    private var needsYouNotificationSound = NotificationSoundChannel.needsYou.shippedDefault.rawValue
    // C11H-246: the flag's own sound and the routine notification dial.
    @AppStorage(FlagSoundSettings.key) private var flagNotificationSound = FlagSoundSettings.defaultValue
    @AppStorage(NotificationLevel.key) private var notificationLevelRaw = NotificationLevel.defaultLevel.rawValue
    @AppStorage(NotificationSoundSettings.customCommandKey) private var notificationCustomCommand = NotificationSoundSettings.defaultCustomCommand
    @AppStorage(NotificationAreaRingSettings.enabledKey) private var notificationPaneRingEnabled = NotificationAreaRingSettings.defaultEnabled
    // C11H-262: how Waiting and Flagged pick the next panel.
    @AppStorage(AttentionJumpOrder.storageKey) private var attentionJumpOrderRaw = AttentionJumpOrder.defaultOrder.rawValue
    @AppStorage(NotificationAreaFlashSettings.enabledKey) private var notificationPaneFlashEnabled = NotificationAreaFlashSettings.defaultEnabled
    @AppStorage(NotificationFlashDurationSettings.storageKey) private var notificationFlashDurationMs: Int = NotificationFlashDurationSettings.defaultMs
    @AppStorage(QuitWarningSettings.warnBeforeQuitKey) private var warnBeforeQuitShortcut = QuitWarningSettings.defaultWarnBeforeQuit
    @AppStorage(QuitTerminalsSettings.keepTerminalsKey) private var keepTerminalsAfterQuit = QuitTerminalsSettings.defaultKeepTerminals
    /// C11H-38: "On launch": always (default), ask, never; same key and values as c11.
    @AppStorage(LaunchResumePolicy.defaultsKey) private var launchResumePolicy = LaunchResumePolicy.always.rawValue
    /// C11H-235: resume a mass outside-signal end's agents by itself. Off by default.
    @AppStorage(HCMassSignalEnd.autoResumeKey) private var massSignalEndAutoResume = false
    @AppStorage(CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
    private var commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
    @AppStorage(CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey)
    private var commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey)
    private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(WorkspacePlacementSettings.placementKey) private var newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
    @AppStorage(LastPanelCloseShortcutSettings.key)
    private var closeWorkspaceOnLastSurfaceShortcut = LastPanelCloseShortcutSettings.defaultValue
    @AppStorage(WorkspaceAutoReorderSettings.key) private var workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
    @AppStorage(ActivityMarkSettings.staticMarksKey)
    private var staticActivityMarks = ActivityMarkSettings.defaultStaticMarks
    @AppStorage(SidebarWorkspaceDetailSettings.hideAllDetailsKey)
    private var sidebarHideAllDetails = SidebarWorkspaceDetailSettings.defaultHideAllDetails
    @AppStorage(SidebarDensitySetting.key)
    private var sidebarDensityRaw = SidebarDensitySetting.defaultValue.rawValue
    @AppStorage(SidebarWorkspaceDetailSettings.showNotificationMessageKey)
    private var sidebarShowNotificationMessage = SidebarWorkspaceDetailSettings.defaultShowNotificationMessage
    @AppStorage(SidebarBranchLayoutSettings.key) private var sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
    @AppStorage(SidebarActiveWorkspaceIndicatorSettings.styleKey)
    private var sidebarActiveWorkspaceIndicatorStyle = SidebarActiveWorkspaceIndicatorSettings.defaultStyle.rawValue
    @AppStorage(ChromeScaleSettings.presetKey)
    private var chromeScalePresetRaw = ChromeScaleSettings.defaultPreset.rawValue
    @AppStorage(ChromeScaleSettings.customMultiplierKey)
    private var chromeScaleCustomMultiplier: Double = Double(ChromeScaleSettings.defaultCustomMultiplier)
    @AppStorage("sidebarShowBranchDirectory") private var sidebarShowBranchDirectory = true
    @AppStorage("sidebarShowPullRequest") private var sidebarShowPullRequest = true
    @AppStorage(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
    private var openSidebarPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser
    @AppStorage(ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
    private var showShortcutHintsOnCommandHold = ShortcutHintDebugSettings.defaultShowHintsOnCommandHold
    @AppStorage("sidebarShowSSH") private var sidebarShowSSH = true
    @AppStorage("sidebarShowPorts") private var sidebarShowPorts = true
    @AppStorage("sidebarShowLog") private var sidebarShowLog = true
    @AppStorage("sidebarShowProgress") private var sidebarShowProgress = true
    @AppStorage("sidebarShowStatusPills") private var sidebarShowMetadata = true
    @AppStorage(SidebarAgentColdSettings.thresholdKey)
    private var sidebarAgentColdThresholdSeconds = SidebarAgentColdSettings.defaultSeconds
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage(C11SidebarBackground.storageKey) private var c11SidebarBackgroundDark = C11SidebarBackground.defaultValue.rawValue

    // [TextBox] TextBox Input settings (plan §4.7)
    @AppStorage(TextBoxInputSettings.enterToSendKey) private var textBoxEnterToSend = TextBoxInputSettings.defaultEnterToSend
    @AppStorage(TextBoxInputSettings.escapeBehaviorKey) private var textBoxEscapeBehavior = TextBoxInputSettings.defaultEscapeBehavior.rawValue
    @AppStorage(TextBoxInputSettings.shortcutBehaviorKey) private var textBoxShortcutBehavior = TextBoxInputSettings.defaultShortcutBehavior.rawValue

    @ObservedObject private var notificationStore = TerminalNotificationStore.shared
    @State private var selectedPage: SettingsPage = .general
    @State private var shortcutResetToken = UUID()
    @State private var showClearBrowserHistoryConfirmation = false
    @State private var showOpenAccessConfirmation = false
    @State private var pendingOpenAccessMode: SocketControlMode?
    @State private var browserHistoryEntryCount: Int = 0
    @State private var detectedImportBrowsers: [InstalledBrowserCandidate] = []
    @State private var browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
    @State private var browserExternalSchemeAllowlistDraft = BrowserExternalSchemeAllowlistDraft(saved: "")
    @State private var socketPasswordDraft = ""
    @State private var socketPasswordStatusMessage: String?
    @State private var socketPasswordStatusIsError = false
    @State private var telemetryValueAtLaunch = TelemetrySettings.userEnabledForCurrentLaunch
    @State private var showLanguageRestartAlert = false
    @State private var isResettingSettings = false

    private var selectedWorkspacePlacement: NewWorkspacePlacement {
        NewWorkspacePlacement(rawValue: newWorkspacePlacement) ?? WorkspacePlacementSettings.defaultPlacement
    }

    private var minimalModeEnabled: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var minimalModeSubtitle: String {
        if minimalModeEnabled {
            return String(
                localized: "settings.app.minimalMode.subtitleOn",
                defaultValue: "Hide the workspace title bar and move workspace controls into the sidebar."
            )
        }
        return String(
            localized: "settings.app.minimalMode.subtitleOff",
            defaultValue: "Use the standard workspace title bar and controls."
        )
    }

    private var keepWorkspaceOpenOnLastSurfaceShortcut: Bool {
        !closeWorkspaceOnLastSurfaceShortcut
    }

    private var keepWorkspaceOpenOnLastSurfaceShortcutBinding: Binding<Bool> {
        Binding(
            get: { keepWorkspaceOpenOnLastSurfaceShortcut },
            set: { closeWorkspaceOnLastSurfaceShortcut = !$0 }
        )
    }

    private var closeWorkspaceOnLastSurfaceShortcutSubtitle: String {
        if keepWorkspaceOpenOnLastSurfaceShortcut {
            return String(
                localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut.subtitleOn",
                defaultValue: "If the focused panel is the last one, the close-panel shortcut still closes only the panel. Close the workspace explicitly with the close-workspace shortcut."
            )
        }
        return String(
            localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut.subtitleOff",
            defaultValue: "If the focused panel is the last one, the close-panel shortcut also closes the workspace."
        )
    }

    private var selectedSocketControlMode: SocketControlMode {
        SocketControlSettings.migrateMode(socketControlMode)
    }

    private var selectedBrowserThemeMode: BrowserThemeMode {
        BrowserThemeSettings.mode(for: browserThemeMode)
    }

    private var browserThemeModeSelection: Binding<String> {
        Binding(
            get: { browserThemeMode },
            set: { newValue in
                browserThemeMode = BrowserThemeSettings.mode(for: newValue).rawValue
            }
        )
    }

    private var browserImportHintVariant: BrowserImportHintVariant {
        BrowserImportHintSettings.variant(for: browserImportHintVariantRaw)
    }

    private var browserImportHintPresentation: BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            variant: browserImportHintVariant,
            showOnBlankPanels: showBrowserImportHintOnBlankPanels,
            isDismissed: isBrowserImportHintDismissed
        )
    }

    private var browserImportHintVisibilityBinding: Binding<Bool> {
        Binding(
            get: { showBrowserImportHintOnBlankPanels },
            set: { newValue in
                showBrowserImportHintOnBlankPanels = newValue
                if newValue {
                    isBrowserImportHintDismissed = false
                }
            }
        )
    }

    private var socketModeSelection: Binding<String> {
        Binding(
            get: { socketControlMode },
            set: { newValue in
                let normalized = SocketControlSettings.migrateMode(newValue)
                if normalized == .allowAll && selectedSocketControlMode != .allowAll {
                    pendingOpenAccessMode = normalized
                    showOpenAccessConfirmation = true
                    return
                }
                socketControlMode = normalized.rawValue
                if normalized != .password {
                    socketPasswordStatusMessage = nil
                    socketPasswordStatusIsError = false
                }
            }
        )
    }

    private var minimalModeBinding: Binding<Bool> {
        Binding(
            get: { minimalModeEnabled },
            set: { newValue in
                workspacePresentationMode = newValue
                    ? WorkspacePresentationModeSettings.Mode.minimal.rawValue
                    : WorkspacePresentationModeSettings.Mode.standard.rawValue
                SettingsWindowController.shared.preserveFocusAfterPreferenceMutation()
            }
        )
    }

    private var hasSocketPasswordConfigured: Bool {
        SocketControlPasswordStore.hasConfiguredPassword()
    }

    private var browserHistorySubtitle: String {
        switch browserHistoryEntryCount {
        case 0:
            return String(localized: "settings.browser.history.subtitleEmpty", defaultValue: "No saved pages yet.")
        case 1:
            return String(localized: "settings.browser.history.subtitleOne", defaultValue: "1 saved page appears in omnibar suggestions.")
        default:
            return String(localized: "settings.browser.history.subtitleMany", defaultValue: "\(browserHistoryEntryCount) saved pages appear in omnibar suggestions.")
        }
    }

    private var browserImportSubtitle: String {
        InstalledBrowserDetector.summaryText(for: detectedImportBrowsers)
    }

    private var browserImportHintSettingsNote: String {
        switch browserImportHintPresentation.settingsStatus {
        case .visible:
            return String(localized: "settings.browser.import.hint.note.visible", defaultValue: "Blank browser panels can show this import suggestion. Hide or re-enable it here.")
        case .hidden:
            return String(localized: "settings.browser.import.hint.note.hidden", defaultValue: "The blank-panel import hint is hidden. Turn it back on any time.")
        case .settingsOnly:
            return String(localized: "settings.browser.import.hint.note.settingsOnly", defaultValue: "Blank panels are on Settings-only mode from the debug window.")
        }
    }

    private var browserInsecureHTTPAllowlistHasUnsavedChanges: Bool {
        browserInsecureHTTPAllowlistDraft != browserInsecureHTTPAllowlist
    }

    private var notificationPermissionStatusText: String {
        notificationStore.authorizationState.statusLabel
    }

    private var notificationPermissionStatusColor: Color {
        switch notificationStore.authorizationState {
        case .authorized, .provisional, .ephemeral:
            return .green
        case .denied:
            return .red
        case .unknown, .notDetermined:
            return .secondary
        }
    }

    private var notificationPermissionSubtitle: String {
        switch notificationStore.authorizationState {
        case .unknown, .notDetermined:
            return String(localized: "settings.notifications.desktop.subtitleNotEnabled", defaultValue: "Desktop notifications are not enabled yet.")
        case .authorized:
            return String(localized: "settings.notifications.desktop.subtitleEnabled", defaultValue: "Desktop notifications are enabled.")
        case .denied:
            return String(localized: "settings.notifications.desktop.subtitleDenied", defaultValue: "Desktop notifications are disabled in System Settings.")
        case .provisional:
            return String(localized: "settings.notifications.desktop.subtitleProvisional", defaultValue: "Desktop notifications are enabled with quiet delivery.")
        case .ephemeral:
            return String(localized: "settings.notifications.desktop.subtitleEphemeral", defaultValue: "Desktop notifications are temporarily enabled.")
        }
    }

    private var notificationPermissionActionTitle: String {
        switch notificationStore.authorizationState {
        case .unknown, .notDetermined:
            return String(localized: "settings.notifications.desktop.action.enable", defaultValue: "Enable")
        case .authorized, .denied, .provisional, .ephemeral:
            return String(localized: "settings.notifications.desktop.action.openSettings", defaultValue: "Open Settings")
        }
    }

    private func handleNotificationPermissionAction() {
        let state = notificationStore.authorizationState.statusLabel
#if DEBUG
        dlog("notification.ui enableTapped state=\(state)")
#endif
        NSLog("notification.ui enableTapped state=%@", state)
        switch notificationStore.authorizationState {
        case .unknown, .notDetermined:
            notificationStore.requestAuthorizationFromSettings()
        case .authorized, .denied, .provisional, .ephemeral:
            notificationStore.openNotificationSettings()
        }
    }

    private func saveSocketPassword() {
        let trimmed = socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.enterFirst", defaultValue: "Enter a password first.")
            socketPasswordStatusIsError = true
            return
        }

        do {
            try SocketControlPasswordStore.savePassword(trimmed)
            socketPasswordDraft = ""
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.saved", defaultValue: "Password saved.")
            socketPasswordStatusIsError = false
        } catch {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.saveFailed", defaultValue: "Failed to save password (\(error.localizedDescription)).")
            socketPasswordStatusIsError = true
        }
    }

    private func clearSocketPassword() {
        do {
            try SocketControlPasswordStore.clearPassword()
            socketPasswordDraft = ""
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.cleared", defaultValue: "Password cleared.")
            socketPasswordStatusIsError = false
        } catch {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.clearFailed", defaultValue: "Failed to clear password (\(error.localizedDescription)).")
            socketPasswordStatusIsError = true
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                SettingsSidebar(selectedPage: selectedPage) { page in
                    proxy.scrollTo(SettingsScrollAnchor.pageTop, anchor: .top)
                    selectedPage = page
                }

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.55))
                    .frame(width: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedPage.title)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.primary.opacity(0.94))
                            Text(selectedPage.helperText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 4)

                        selectedPageContent
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 48)
                    .padding(.bottom, 20)
                    .id(SettingsScrollAnchor.pageTop)
                }
                .onReceive(NotificationCenter.default.publisher(for: SettingsNavigationRequest.notificationName)) { notification in
                    guard let target = SettingsNavigationRequest.target(from: notification) else { return }
                    selectedPage = SettingsPage.page(for: target)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .toggleStyle(.switch)
        .onAppear {
            BrowserHistoryStore.shared.loadIfNeeded()
            notificationStore.refreshAuthorizationStatus()
            browserThemeMode = BrowserThemeSettings.mode(defaults: .standard).rawValue
            browserImportHintVariantRaw = BrowserImportHintSettings.variant(for: browserImportHintVariantRaw).rawValue
            browserHistoryEntryCount = BrowserHistoryStore.shared.entries.count
            browserInsecureHTTPAllowlistDraft = browserInsecureHTTPAllowlist
            browserExternalSchemeAllowlistDraft = BrowserExternalSchemeAllowlistDraft(saved: browserExternalSchemeAllowlist)
            refreshDetectedImportBrowsers()
        }
        // C11H-319: playback copies follow the sounds in use.
        .onChange(of: notificationSound) { _, _ in NotificationSoundPlayback.syncInBackground() }
        .onChange(of: needsYouNotificationSound) { _, _ in NotificationSoundPlayback.syncInBackground() }
        .onChange(of: flagNotificationSound) { _, _ in NotificationSoundPlayback.syncInBackground() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            browserExternalSchemeAllowlistDraft.settingsWindowWillClose(notification, stored: browserExternalSchemeAllowlist)
        }
        .onChange(of: browserExternalSchemeAllowlist) { _, newValue in
            // "Always allow" adds a line while Settings is open; unsaved edits win.
            browserExternalSchemeAllowlistDraft.storedValueChanged(to: newValue)
        }
        .onChange(of: browserInsecureHTTPAllowlist) { oldValue, newValue in
            // Keep draft in sync with external changes unless the operator has local unsaved edits.
            if browserInsecureHTTPAllowlistDraft == oldValue {
                browserInsecureHTTPAllowlistDraft = newValue
            }
        }
        .onReceive(BrowserHistoryStore.shared.$entries) { entries in
            browserHistoryEntryCount = entries.count
        }
        .confirmationDialog(
            String(localized: "settings.browser.history.clearDialog.title", defaultValue: "Clear browser history?"),
            isPresented: $showClearBrowserHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.browser.history.clearDialog.confirm", defaultValue: "Clear History"), role: .destructive) {
                BrowserHistoryStore.shared.clearHistory()
            }
            Button(String(localized: "settings.browser.history.clearDialog.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.browser.history.clearDialog.message", defaultValue: "This removes visited-page suggestions from the browser omnibar."))
        }
        .confirmationDialog(
            String(localized: "settings.automation.openAccess.dialog.title", defaultValue: "Enable full open access?"),
            isPresented: $showOpenAccessConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.automation.openAccess.dialog.confirm", defaultValue: "Enable Full Open Access"), role: .destructive) {
                socketControlMode = (pendingOpenAccessMode ?? .allowAll).rawValue
                pendingOpenAccessMode = nil
            }
            Button(String(localized: "settings.automation.openAccess.dialog.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingOpenAccessMode = nil
            }
        } message: {
            Text(String(localized: "settings.automation.openAccess.dialog.message", defaultValue: "This disables ancestry and password checks and opens the socket to all local users. Only enable when you understand the risk."))
        }
        .confirmationDialog(
            String(localized: "settings.app.language.restartDialog.title", defaultValue: "Restart c11 to switch language?"),
            isPresented: $showLanguageRestartAlert,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.app.language.restartDialog.confirm", defaultValue: "Restart Now")) {
                relaunchApp()
            }
            Button(String(localized: "settings.app.language.restartDialog.later", defaultValue: "Later"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var selectedPageContent: some View {
        switch selectedPage {
        case .general:
            generalSettingsPage
        case .agents:
            agentsSettingsPage
        case .herderTopography:
            herderTopographySettingsPage
        case .appearance:
            appearanceSettingsPage
        case .workspaceSidebar:
            workspaceSidebarSettingsPage
        case .browser:
            browserSettingsPage
        case .notifications:
            notificationSettingsPage
        case .input:
            inputSettingsPage
        case .keyboardShortcuts:
            keyboardShortcutSettingsPage
        case .automation:
            automationSettingsPage
        case .dataPrivacy:
            dataPrivacySettingsPage
        case .advanced:
            advancedSettingsPage
        }
    }

    @ViewBuilder
    private var generalSettingsPage: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.language", defaultValue: "Language"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.app.language", defaultValue: "Language"),
                subtitle: appLanguage != LanguageSettings.languageAtLaunch.rawValue
                    ? String(localized: "settings.app.language.restartSubtitle", defaultValue: "Restart c11 to apply")
                    : nil,
                controlWidth: pickerColumnWidth
            ) {
                Picker("", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: appLanguage) { newValue in
                    guard !isResettingSettings else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                        let current = appLanguage
                        if let lang = AppLanguage(rawValue: current) {
                            LanguageSettings.apply(lang)
                        }
                        if current != LanguageSettings.languageAtLaunch.rawValue {
                            showLanguageRestartAlert = true
                        }
                    }
                }
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.launchBehavior", defaultValue: "Launch"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.app.onLaunch", defaultValue: "On launch"),
                subtitle: String(localized: "settings.app.onLaunch.hint",
                    defaultValue: "Hold Option while c11 starts to choose for one launch."),
                controlWidth: pickerColumnWidth
            ) {
                Picker("", selection: Binding(
                    get: {
                        LaunchResumePolicy(rawValue: launchResumePolicy.trimmingCharacters(in: .whitespaces).lowercased())
                            .map { $0 == .ask && !LaunchResumePolicy.offersAskOption ? .always : $0 } ?? .always
                    },
                    set: { launchResumePolicy = $0.rawValue }
                )) {
                    Text(String(localized: "settings.app.onLaunch.always", defaultValue: "Resume previous session"))
                        .tag(LaunchResumePolicy.always)
                    if LaunchResumePolicy.offersAskOption {
                        Text(String(localized: "settings.app.onLaunch.ask", defaultValue: "Ask which workspaces to resume"))
                            .tag(LaunchResumePolicy.ask)
                    }
                    Text(String(localized: "settings.app.onLaunch.never", defaultValue: "Start fresh"))
                        .tag(LaunchResumePolicy.never)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.massSignalEndAutoResume",
                    defaultValue: "Resume agents after a mass outside-signal end"),
                subtitle: String(localized: "settings.app.massSignalEndAutoResume.hint",
                    defaultValue: "When 3 or more agents' terminals end by a signal from outside c11 within 5 seconds, resume their conversations one by one. Off: they wait for Resume all in the restore strip.")
            ) {
                Toggle("", isOn: $massSignalEndAutoResume)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-mass-signal-end-auto-resume")
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.quitBehavior", defaultValue: "Quit Behavior"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit"),
                subtitle: warnBeforeQuitShortcut
                    ? String(localized: "settings.app.warnBeforeQuit.confirmOn", defaultValue: "Ask for confirmation before c11 quits.")
                    : String(localized: "settings.app.warnBeforeQuit.confirmOff", defaultValue: "c11 quits immediately without confirmation.")
            ) {
                Toggle("", isOn: $warnBeforeQuitShortcut)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            // C11H-267: the switch the c11 2.0 upgrade note names.
            SettingsCardRow(
                String(localized: "settings.app.keepTerminalsAfterQuit", defaultValue: "Keep Terminals After Quit"),
                subtitle: keepTerminalsAfterQuit
                    ? String(localized: "settings.app.keepTerminalsAfterQuit.on",
                             defaultValue: "Terminals, agents and jobs keep running after c11 quits, and come back when you open it.")
                    : String(localized: "settings.app.keepTerminalsAfterQuit.off",
                             defaultValue: "Quitting c11 ends every terminal on this Mac and the jobs inside them.")
            ) {
                Toggle("", isOn: $keepTerminalsAfterQuit)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-keep-terminals-after-quit")
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.surfaces", defaultValue: "Areas & Panels"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.app.internalBrowser", defaultValue: "Internal Browser"),
                subtitle: internalBrowserEnabled
                    ? String(localized: "settings.app.internalBrowser.subtitleOn", defaultValue: "Allow creating internal browser panels. Open browser panels keep running when turned off.")
                    : String(localized: "settings.app.internalBrowser.subtitleOff", defaultValue: "Block new internal browser panels. The Browser spawn button is hidden and CLI/socket creation is rejected.")
            ) {
                Toggle("", isOn: $internalBrowserEnabled)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.markdownSurfaces", defaultValue: "Markdown Panels"),
                subtitle: markdownSurfacesEnabled
                    ? String(localized: "settings.app.markdownSurfaces.subtitleOn", defaultValue: "Allow creating markdown panels. Open markdown panels keep running when turned off.")
                    : String(localized: "settings.app.markdownSurfaces.subtitleOff", defaultValue: "Block new markdown panels. The Markdown spawn button is hidden and CLI/socket creation is rejected.")
            ) {
                Toggle("", isOn: $markdownSurfacesEnabled)
                    .labelsHidden()
                    .controlSize(.small)
            }

            if markdownSurfacesEnabled {
                SettingsCardDivider()

                SettingsCardRow(
                    String(localized: "settings.app.markdownSpawnButton", defaultValue: "Markdown Button in Panel Bar"),
                    subtitle: markdownSpawnButtonVisible
                        ? String(localized: "settings.app.markdownSpawnButton.subtitleOn", defaultValue: "The panel bar shows the Markdown spawn button. Turn off to reclaim the slot; markdown panels stay available via the CLI and command palette.")
                        : String(localized: "settings.app.markdownSpawnButton.subtitleOff", defaultValue: "The Markdown spawn button is hidden. Markdown panels remain fully available via the CLI and command palette.")
                ) {
                    Toggle("", isOn: $markdownSpawnButtonVisible)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.showSurfaceIdsInTabTitles", defaultValue: "Show Panel Numbers in Panel Titles"),
                subtitle: showSurfaceIdsInPanelTitles
                    ? String(localized: "settings.app.showSurfaceIdsInTabTitles.subtitleOn", defaultValue: "Panels display their panel number (\"292: Build agent\"). Say the number to address a panel; agents target it as panel:N.")
                    : String(localized: "settings.app.showSurfaceIdsInTabTitles.subtitleOff", defaultValue: "Panels display their title only. Turn on to prefix every panel with its addressable panel number.")
            ) {
                Toggle("", isOn: $showSurfaceIdsInPanelTitles)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsShowSurfaceIdsToggle")
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.showWorkspaceIdsInSidebar", defaultValue: "Show Workspace Numbers in Sidebar"),
                subtitle: showWorkspaceIdsInSidebar
                    ? String(localized: "settings.app.showWorkspaceIdsInSidebar.subtitleOn", defaultValue: "Workspace cards display their workspace number in the top-right corner. Say the number to address a workspace; agents target it as workspace:N.")
                    : String(localized: "settings.app.showWorkspaceIdsInSidebar.subtitleOff", defaultValue: "Workspace cards display their title only. Turn on to show each workspace's addressable number.")
            ) {
                Toggle("", isOn: $showWorkspaceIdsInSidebar)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsShowWorkspaceIdsToggle")
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.tabLayout", defaultValue: "Panel Layout"),
                subtitle: PanelLayoutSettings.mode(for: panelLayoutMode) == .rail
                    ? String(localized: "settings.app.tabLayout.subtitleRail", defaultValue: "A vertical panel list docks on each area's left edge; the count button toggles it.")
                    : String(localized: "settings.app.tabLayout.subtitleTabs", defaultValue: "A strip of panels across the top of each area; the count button opens the full list."),
                controlWidth: pickerColumnWidth
            ) {
                Picker("", selection: panelLayoutSelection) {
                    Text(String(localized: "settings.app.tabLayout.tabs", defaultValue: "Strip"))
                        .tag(PanelLayoutSettings.Mode.strip.rawValue)
                    Text(String(localized: "settings.app.tabLayout.rail", defaultValue: "Rail"))
                        .tag(PanelLayoutSettings.Mode.rail.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("SettingsTabLayoutPicker")
            }
        }
    }

    /// c11h: Herder Topography. What a herder core is, the map of every
    /// machine (a gear on each to name, color, update or remove it), Add
    /// Machine with its help, and whether new terminals ask where to run.
    @ViewBuilder
    private var herderTopographySettingsPage: some View {
        HerderTopographyExplainer()

        SettingsSectionHeader(title: String(localized: "settings.section.topography", defaultValue: "Your Topography"))
            .id(SettingsNavigationTarget.machines)
        SettingsCard {
            HerderTopographyMapSection()
        }

        SettingsSectionHeader(title: String(localized: "settings.section.newTerminals", defaultValue: "New Terminals"))
        SettingsCard {
            // C11H-138: the machine picker on New Terminal and agent launch.
            SettingsCardRow(
                String(localized: "settings.machines.ask", defaultValue: "Ask which machine for new terminals"),
                subtitle: askMachineForNewTerminals
                    ? String(localized: "settings.machines.ask.subtitleOn", defaultValue: "When another machine is connected, New Terminal and agent launches ask where to run. Press its number to choose; Return picks this Mac.")
                    : String(localized: "settings.machines.ask.subtitleOff", defaultValue: "New terminals and agents open on this Mac. File > New Terminal on <Machine> still opens one elsewhere.")
            ) {
                Toggle("", isOn: $askMachineForNewTerminals)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsAskMachineToggle")
            }
        }
    }

    @ViewBuilder
    private var appearanceSettingsPage: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.interfaceSize", defaultValue: "Interface Size"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.interfaceSize.title", defaultValue: "Interface Size"),
                subtitle: String(
                    localized: "settings.interfaceSize.subtitle",
                    defaultValue: "How big c11 draws the sidebar and the title bar above each panel: their text, tags and spacing. Terminal text has its own size: Area > Increase Font Size."
                ),
                controlWidth: pickerColumnWidth,
                selection: $chromeScalePresetRaw
            ) {
                ForEach(ChromeScaleSettings.Preset.allCases) { preset in
                    Text(preset.displayName).tag(preset.rawValue)
                }
            }

            if ChromeScaleSettings.preset(for: chromeScalePresetRaw) == .custom {
                SettingsCardDivider()
                SettingsCardRow(
                    String(localized: "settings.chromeScale.custom.label", defaultValue: "Custom Multiplier"),
                    subtitle: String(
                        localized: "settings.chromeScale.custom.subtitle",
                        defaultValue: "Drag to fine-tune scale. Range 0.50× to 3.00×."
                    )
                ) {
                    HStack(spacing: 8) {
                        Slider(
                            value: $chromeScaleCustomMultiplier,
                            in: Double(ChromeScaleSettings.customMultiplierRange.lowerBound)
                                ... Double(ChromeScaleSettings.customMultiplierRange.upperBound),
                            step: 0.05
                        )
                        Text(String(format: "%.2f×", chromeScaleCustomMultiplier))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                    .frame(width: pickerColumnWidth)
                }
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.theme", defaultValue: "Theme"))
        SettingsCard {
            ThemePreviewGallery()
        }

        SettingsSectionHeader(title: String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar Appearance"))
        SettingsCard {
            // c11's Dark-slot sidebar background (C11H-32), stored under a c11-only key.
            SettingsCardRow(
                String(localized: "settings.sidebarBackground", defaultValue: "Sidebar Background"),
                subtitle: String(localized: "settings.sidebarBackground.subtitleOneTheme", defaultValue: "From Theme draws the theme's own background, or Sunset Mall for a theme without one. Sunset Mall and Outrun Horizon replace the theme's background. None always uses the tint."),
                controlWidth: pickerColumnWidth
            ) {
                Picker("", selection: Binding(
                    get: { C11SidebarBackground.resolve(c11SidebarBackgroundDark).rawValue },
                    set: { c11SidebarBackgroundDark = $0 }
                )) {
                    ForEach(C11SidebarBackground.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("SettingsSidebarBackgroundPicker")
            }
        }
    }

    @ViewBuilder
    private var workspaceSidebarSettingsPage: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.workspaceBehavior", defaultValue: "Workspace Behavior"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.app.newWorkspacePlacement", defaultValue: "New Workspace Placement"),
                subtitle: selectedWorkspacePlacement.description,
                controlWidth: pickerColumnWidth,
                selection: $newWorkspacePlacement
            ) {
                ForEach(NewWorkspacePlacement.allCases) { placement in
                    Text(placement.displayName).tag(placement.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode"),
                subtitle: minimalModeSubtitle
            ) {
                Toggle("", isOn: minimalModeBinding)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsMinimalModeToggle")
                    .accessibilityLabel(
                        String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode")
                    )
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut", defaultValue: "Keep Workspace When Last Panel Closes"),
                subtitle: closeWorkspaceOnLastSurfaceShortcutSubtitle
            ) {
                Toggle("", isOn: keepWorkspaceOpenOnLastSurfaceShortcutBinding)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.reorderOnNotification", defaultValue: "Reorder on Notification"),
                subtitle: String(localized: "settings.app.reorderOnNotification.subtitle", defaultValue: "Move workspaces to the top when they receive a notification. Disable for stable shortcut positions.")
            ) {
                Toggle("", isOn: $workspaceAutoReorder)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.staticMarks", defaultValue: "Static marks"),
                subtitle: String(
                    localized: "settings.app.staticMarks.subtitle",
                    defaultValue: "Stop normal lifecycle motion. Flagged working and waiting marks remain animated unless Reduce Motion is enabled."
                )
            ) {
                Toggle("", isOn: $staticActivityMarks)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(
                        String(localized: "settings.app.staticMarks", defaultValue: "Static marks")
                    )
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.sidebarDetail", defaultValue: "Sidebar Detail"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.app.sidebarDensity", defaultValue: "Sidebar Density"),
                subtitle: {
                    switch SidebarDensitySetting.resolve(sidebarDensityRaw) {
                    case .automatic:
                        return String(localized: "settings.app.sidebarDensity.subtitleAutomatic", defaultValue: "Full cards while every workspace fits; two-line cards once they would scroll.")
                    case .compact:
                        return String(localized: "settings.app.sidebarDensity.subtitleCompact", defaultValue: "Always two-line cards: name, number, agent marks and counts. Hover a card for the rest.")
                    case .cards:
                        return String(localized: "settings.app.sidebarDensity.subtitleCards", defaultValue: "Always full cards; the sidebar scrolls when they do not fit.")
                    }
                }(),
                controlWidth: pickerColumnWidth,
                selection: $sidebarDensityRaw
            ) {
                Text(String(localized: "settings.app.sidebarDensity.automatic", defaultValue: "Automatic")).tag(SidebarDensitySetting.automatic.rawValue)
                Text(String(localized: "settings.app.sidebarDensity.compact", defaultValue: "Compact")).tag(SidebarDensitySetting.compact.rawValue)
                Text(String(localized: "settings.app.sidebarDensity.cards", defaultValue: "Cards")).tag(SidebarDensitySetting.cards.rawValue)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.hideAllSidebarDetails", defaultValue: "Hide All Sidebar Details"),
                subtitle: sidebarHideAllDetails
                    ? String(localized: "settings.app.hideAllSidebarDetails.subtitleOn", defaultValue: "Show only the workspace title row. Overrides the detail toggles below.")
                    : String(localized: "settings.app.hideAllSidebarDetails.subtitleOff", defaultValue: "Show secondary workspace details as controlled by the toggles below.")
            ) {
                Toggle("", isOn: $sidebarHideAllDetails)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsPickerRow(
                String(localized: "settings.app.sidebarBranchLayout", defaultValue: "Sidebar Branch Layout"),
                subtitle: sidebarBranchVerticalLayout
                    ? String(localized: "settings.app.sidebarBranchLayout.subtitleVertical", defaultValue: "Vertical: each branch appears on its own line.")
                    : String(localized: "settings.app.sidebarBranchLayout.subtitleInline", defaultValue: "Inline: all branches share one line."),
                controlWidth: pickerColumnWidth,
                selection: $sidebarBranchVerticalLayout
            ) {
                Text(String(localized: "settings.app.sidebarBranchLayout.vertical", defaultValue: "Vertical")).tag(true)
                Text(String(localized: "settings.app.sidebarBranchLayout.inline", defaultValue: "Inline")).tag(false)
            }
            .disabled(sidebarHideAllDetails)

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.showNotificationMessage", defaultValue: "Show Notification Message in Sidebar"),
                subtitle: String(localized: "settings.app.showNotificationMessage.subtitle", defaultValue: "Display the latest notification message below the workspace title.")
            ) {
                Toggle("", isOn: $sidebarShowNotificationMessage)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(sidebarHideAllDetails)

            SettingsCardDivider()

            SettingsCardRow(
                // C11-104 v2 — relabeled. The toggle key
                // `sidebarShowBranchDirectory` is preserved so existing
                // user prefs survive the migration; the surface it gates
                // is now the worktree+branch chip row.
                String(
                    localized: "settings.app.showWorktreeBranchChips",
                    defaultValue: "Show worktree + branch chips in sidebar"
                ),
                subtitle: String(
                    localized: "settings.app.showWorktreeBranchChips.subtitle",
                    defaultValue: "Render worktree (colored-dot prefix) and branch chips on each workspace row — derived from cwd and gitfs."
                )
            ) {
                Toggle("", isOn: $sidebarShowBranchDirectory)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(sidebarHideAllDetails)

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.showPullRequests", defaultValue: "Show Pull Requests in Sidebar"),
                subtitle: String(localized: "settings.app.showPullRequests.subtitle", defaultValue: "Display review items (PR/MR/etc.) with status, number, and clickable link.")
            ) {
                Toggle("", isOn: $sidebarShowPullRequest)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(sidebarHideAllDetails)

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.openSidebarPRLinks", defaultValue: "Open Sidebar PR Links in c11 Browser"),
                subtitle: openSidebarPullRequestLinksInCmuxBrowser
                    ? String(localized: "settings.app.openSidebarPRLinks.subtitleOn", defaultValue: "Clicks open inside c11 browser.")
                    : String(localized: "settings.app.openSidebarPRLinks.subtitleOff", defaultValue: "Clicks open in your default browser.")
            ) {
                Toggle("", isOn: $openSidebarPullRequestLinksInCmuxBrowser)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(sidebarHideAllDetails)

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.showSSH", defaultValue: "Show SSH in Sidebar"),
                subtitle: String(localized: "settings.app.showSSH.subtitle", defaultValue: "Display the SSH target for remote workspaces in its own row.")
            ) {
                Toggle("", isOn: $sidebarShowSSH)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.sidebarMetadata", defaultValue: "Sidebar Metadata"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.app.showPorts", defaultValue: "Show Listening Ports in Sidebar"),
                subtitle: String(localized: "settings.app.showPorts.subtitle", defaultValue: "Display detected listening ports for the active workspace.")
            ) {
                Toggle("", isOn: $sidebarShowPorts)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(sidebarHideAllDetails)

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.showLog", defaultValue: "Show Latest Log in Sidebar"),
                subtitle: String(localized: "settings.app.showLog.subtitle", defaultValue: "Display the latest imperative log/status message.")
            ) {
                Toggle("", isOn: $sidebarShowLog)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(sidebarHideAllDetails)

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.showProgress", defaultValue: "Show Progress in Sidebar"),
                subtitle: String(localized: "settings.app.showProgress.subtitle", defaultValue: "Show the progress bar set by set_progress.")
            ) {
                Toggle("", isOn: $sidebarShowProgress)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(sidebarHideAllDetails)

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.showMetadata", defaultValue: "Show Custom Metadata in Sidebar"),
                subtitle: String(localized: "settings.app.showMetadata.subtitle", defaultValue: "Display custom metadata from report_meta/set_status and report_meta_block.")
            ) {
                Toggle("", isOn: $sidebarShowMetadata)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(sidebarHideAllDetails)

            SettingsCardDivider()

            SettingsCardRow(
                String(
                    localized: "settings.app.sidebarAgentColdThreshold.title",
                    defaultValue: "Agents Go Cold After"
                ),
                subtitle: String(
                    localized: "settings.app.sidebarAgentColdThreshold.subtitle",
                    defaultValue: "An agent whose prompt cache c11 can see goes Cold when the cache expires. Other agents go Cold after this long without a submitted task or lifecycle activity."
                )
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding<Double>(
                            get: { sidebarAgentColdThresholdSeconds },
                            set: {
                                sidebarAgentColdThresholdSeconds =
                                    SidebarAgentColdSettings.clamp($0)
                            }
                        ),
                        in: SidebarAgentColdSettings.minSeconds...SidebarAgentColdSettings.maxSeconds,
                        step: 60
                    )
                    .controlSize(.small)
                    .frame(width: 140)
                    .accessibilityLabel(
                        String(
                            localized: "settings.app.sidebarAgentColdThreshold.title",
                            defaultValue: "Agents Go Cold After"
                        )
                    )
                    Text(sidebarDecayThresholdLabel(sidebarAgentColdThresholdSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 56, alignment: .trailing)
                }
            }
            .disabled(sidebarHideAllDetails)
        }
    }

    /// Present a duration stored in seconds as a compact human label.
    private func sidebarDecayThresholdLabel(_ seconds: Double) -> String {
        if seconds >= 60 {
            let minutes = seconds / 60
            return String(format: String(localized: "settings.app.sidebarDecay.unit.minutes", defaultValue: "%.1f min"), minutes)
        }
        return String(format: String(localized: "settings.app.sidebarDecay.unit.seconds", defaultValue: "%d s"), Int(seconds))
    }

    @ViewBuilder
    private var browserSettingsPage: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.search", defaultValue: "Search"))
            .id(SettingsNavigationTarget.browser)
            .accessibilityIdentifier("SettingsBrowserSection")
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.browser.searchEngine", defaultValue: "Default Search Engine"),
                subtitle: String(localized: "settings.browser.searchEngine.subtitle", defaultValue: "Used by the browser address bar when input is not a URL."),
                controlWidth: pickerColumnWidth,
                selection: $browserSearchEngine
            ) {
                ForEach(BrowserSearchEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions")) {
                Toggle("", isOn: $browserSearchSuggestionsEnabled)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.browserAppearance", defaultValue: "Browser Appearance"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.browser.theme", defaultValue: "Browser Theme"),
                subtitle: selectedBrowserThemeMode == .system
                    ? String(localized: "settings.browser.theme.subtitleSystem", defaultValue: "System follows app and macOS appearance.")
                    : String(localized: "settings.browser.theme.subtitleForced", defaultValue: "\(selectedBrowserThemeMode.displayName) forces that color scheme for compatible pages."),
                controlWidth: pickerColumnWidth,
                selection: browserThemeModeSelection
            ) {
                ForEach(BrowserThemeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.linkRouting", defaultValue: "Link Routing"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in c11 Browser"),
                subtitle: String(localized: "settings.browser.openTerminalLinks.subtitle", defaultValue: "When off, links clicked in terminal output open in your default browser.")
            ) {
                Toggle("", isOn: $openTerminalLinksInCmuxBrowser)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal"),
                subtitle: String(localized: "settings.browser.interceptOpen.subtitle", defaultValue: "When off, `open https://...` and `open http://...` always use your default browser.")
            ) {
                Toggle("", isOn: $interceptTerminalOpenCommandInCmuxBrowser)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.browser.linkRouting.note", defaultValue: "Link interception changes where terminal URL actions land. Sidebar PR links are controlled on Workspace & Sidebar."))
        }

        SettingsSectionHeader(title: String(localized: "settings.section.securityExceptions", defaultValue: "Security & Exceptions"))
        SettingsCard {
            if openTerminalLinksInCmuxBrowser || interceptTerminalOpenCommandInCmuxBrowser {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsCardRow(
                        String(localized: "settings.browser.hostWhitelist", defaultValue: "Hosts to Open in Embedded Browser"),
                        subtitle: String(localized: "settings.browser.hostWhitelist.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. Only these hosts open in c11. Others open in your default browser. One host or wildcard per line (for example: example.com, *.internal.example). Leave empty to open all hosts in c11.")
                    ) {
                        EmptyView()
                    }

                    TextEditor(text: $browserHostWhitelist)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                SettingsCardDivider()

                VStack(alignment: .leading, spacing: 6) {
                    SettingsCardRow(
                        String(localized: "settings.browser.externalPatterns", defaultValue: "URLs to Always Open Externally"),
                        subtitle: String(localized: "settings.browser.externalPatterns.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. One rule per line. Plain text matches any URL substring, or prefix with `re:` for regex (for example: openai.com/usage, re:^https?://[^/]*\\.example\\.com/(billing|usage)).")
                    ) {
                        EmptyView()
                    }

                    TextEditor(text: $browserExternalOpenPatterns)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                SettingsCardDivider()
            }

            VStack(alignment: .leading, spacing: 6) {
                SettingsCardRow(
                    String(localized: "settings.browser.externalSchemeAllowlist", defaultValue: "Sites Allowed to Open Apps"),
                    subtitle: String(localized: "settings.browser.externalSchemeAllowlist.subtitle", defaultValue: "A page that links to another app (vnc:, smb:, zoommtg: and the like) asks before it opens. \u{201C}Always allow\u{201D} adds a line here: the site, then the link type (for example: https://zoom.us zoommtg). Delete a line and Save to make that site ask again.")
                ) {
                    EmptyView()
                }

                TextEditor(text: $browserExternalSchemeAllowlistDraft.text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("SettingsBrowserExternalSchemeAllowlistField")

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let invalid = browserExternalSchemeAllowlistDraft.invalidLine {
                        Text(String(localized: "settings.browser.externalSchemeAllowlist.invalidLine", defaultValue: "Line \(invalid.number) can never match: \(invalid.text). Write the site, then the link type (for example: https://zoom.us zoommtg)."))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("SettingsBrowserExternalSchemeAllowlistInvalidLine")
                    }

                    Spacer(minLength: 0)

                    Button(String(localized: "settings.browser.externalSchemeAllowlist.save", defaultValue: "Save")) {
                        saveBrowserExternalSchemeAllowlist()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!browserExternalSchemeAllowlistDraft.canSave)
                    .accessibilityIdentifier("SettingsBrowserExternalSchemeAllowlistSaveButton")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            SettingsCardDivider()

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "settings.browser.httpAllowlist", defaultValue: "HTTP Hosts Allowed in Embedded Browser"))
                    .font(.system(size: 13, weight: .semibold))

                Text(String(localized: "settings.browser.httpAllowlist.description", defaultValue: "Controls which HTTP (non-HTTPS) hosts can open in c11 without a warning prompt. Defaults include localhost, 127.0.0.1, ::1, 0.0.0.0, and *.localtest.me."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $browserInsecureHTTPAllowlistDraft)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(minHeight: 86)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .accessibilityIdentifier("SettingsBrowserHTTPAllowlistField")

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)

                        Button(String(localized: "settings.browser.httpAllowlist.save", defaultValue: "Save")) {
                            saveBrowserInsecureHTTPAllowlist()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!browserInsecureHTTPAllowlistHasUnsavedChanges)
                        .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Spacer(minLength: 0)
                            Button(String(localized: "settings.browser.httpAllowlist.save", defaultValue: "Save")) {
                                saveBrowserInsecureHTTPAllowlist()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!browserInsecureHTTPAllowlistHasUnsavedChanges)
                            .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }

        SettingsSectionHeader(title: String(localized: "settings.section.import", defaultValue: "Import"))
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "settings.browser.import", defaultValue: "Import Browser Data"))
                        .font(.system(size: 13, weight: .semibold))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "browser.import.hint.title", defaultValue: "Import browser data"))
                            .font(.system(size: 12.5, weight: .semibold))

                        Text(browserImportSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(String(localized: "browser.import.hint.settingsFootnote", defaultValue: "You can always find this in Settings > Browser."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                    )
                }

                HStack(spacing: 8) {
                    Button(String(localized: "settings.browser.import.choose", defaultValue: "Choose…")) {
                        DispatchQueue.main.async {
                            BrowserDataImportCoordinator.shared.presentImportDialog()
                            refreshDetectedImportBrowsers()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsBrowserImportChooseButton")

                    Button(String(localized: "settings.browser.import.refresh", defaultValue: "Refresh")) {
                        refreshDetectedImportBrowsers()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .accessibilityIdentifier("SettingsBrowserImportActions")

                Toggle(
                    String(localized: "settings.browser.import.hint.show", defaultValue: "Show import hint on blank browser panels"),
                    isOn: browserImportHintVisibilityBinding
                )
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBrowserImportHintToggle")

                Text(browserImportHintSettingsNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(SettingsNavigationTarget.browserImport)
            .accessibilityIdentifier("SettingsBrowserImportSection")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var notificationSettingsPage: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.inAppSignals", defaultValue: "In-App Signals"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.notifications.jumpOrder.title", defaultValue: "Waiting and Flagged Order"),
                subtitle: String(
                    localized: "settings.notifications.jumpOrder.subtitle",
                    defaultValue: "Current workspace first clears the workspace you are in, then moves on. Oldest first goes to the oldest wait anywhere. Flagged buttons follow the same order."
                ),
                controlWidth: pickerColumnWidth,
                selection: $attentionJumpOrderRaw,
                accessibilityId: "SettingsAttentionJumpOrderPicker"
            ) {
                ForEach(AttentionJumpOrder.allCases) { order in
                    Text(order.displayName).tag(order.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.paneRing.title", defaultValue: "Unread Area Ring"),
                subtitle: String(localized: "settings.notifications.paneRing.subtitle", defaultValue: "Rings unread areas in blue.")
            ) {
                Toggle("", isOn: $notificationPaneRingEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(
                        String(localized: "settings.notifications.paneRing.title", defaultValue: "Unread Area Ring")
                    )
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.paneFlash.title", defaultValue: "Area Flash"),
                subtitle: String(localized: "settings.notifications.paneFlash.subtitle", defaultValue: "Flashes a blue outline when c11 highlights an area.")
            ) {
                Toggle("", isOn: $notificationPaneFlashEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(
                        String(localized: "settings.notifications.paneFlash.title", defaultValue: "Area Flash")
                    )
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.flashDuration.title", defaultValue: "Flash Duration"),
                subtitle: String(localized: "settings.notifications.flashDuration.subtitle", defaultValue: "How long the flash pulse lasts before fading.")
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding<Double>(
                            get: { Double(notificationFlashDurationMs) },
                            set: { newValue in
                                let clamped = min(
                                    Double(NotificationFlashDurationSettings.maxMs),
                                    max(Double(NotificationFlashDurationSettings.minMs), newValue)
                                )
                                notificationFlashDurationMs = Int((clamped / 100.0).rounded()) * 100
                            }
                        ),
                        in: Double(NotificationFlashDurationSettings.minMs)...Double(NotificationFlashDurationSettings.maxMs),
                        step: 100
                    )
                    .controlSize(.small)
                    .frame(width: 140)
                    .accessibilityLabel(
                        String(localized: "settings.notifications.flashDuration.title", defaultValue: "Flash Duration")
                    )
                    Text(String(format: String(localized: "settings.notifications.flashDuration.unit.ms", defaultValue: "%d ms"), notificationFlashDurationMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 56, alignment: .trailing)
                }
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.systemSignals", defaultValue: "System Signals"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.notifications.desktop.title", defaultValue: "Desktop Notifications"),
                subtitle: notificationPermissionSubtitle
            ) {
                HStack(spacing: 6) {
                    Text(notificationPermissionStatusText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(notificationPermissionStatusColor)
                        .frame(width: 98, alignment: .trailing)

                    Button(notificationPermissionActionTitle) {
                        handleNotificationPermissionAction()
                    }
                    .controlSize(.small)

                    Button(String(localized: "settings.notifications.desktop.sendTest", defaultValue: "Send Test")) {
                        notificationStore.sendSettingsTestNotification()
                    }
                    .controlSize(.small)
                }
            }

            SettingsCardDivider()

            SettingsPickerRow(
                String(localized: "settings.notifications.level.title", defaultValue: "Notification Level"),
                subtitle: (NotificationLevel(rawValue: notificationLevelRaw) ?? .normal).summary,
                controlWidth: pickerColumnWidth,
                selection: $notificationLevelRaw,
                accessibilityId: "SettingsNotificationLevelPicker"
            ) {
                ForEach(NotificationLevel.allCases, id: \.rawValue) { level in
                    Text(level.displayLabel).tag(level.rawValue)
                }
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.sound", defaultValue: "Sound"))
        SettingsCard {
            // C11H-319: one sound per channel, each its own setting.
            SettingsCardRow(
                String(localized: "settings.notifications.turnEndSound.title", defaultValue: "Turn End Sound"),
                subtitle: String(localized: "settings.notifications.turnEndSound.subtitle", defaultValue: "Played when an agent finishes its turn, and for other routine notices."),
                controlWidth: notificationSoundControlWidth
            ) {
                NotificationSoundPicker(
                    value: $notificationSound,
                    allowsNone: true,
                    inheritsFlagSound: false,
                    accessibilityID: "SettingsTurnEndSoundPicker"
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.needsYouSound.title", defaultValue: "Needs You Sound"),
                subtitle: String(localized: "settings.notifications.needsYouSound.subtitle", defaultValue: "Played when an agent stops on you: a permission prompt, a question, a plan."),
                controlWidth: notificationSoundControlWidth
            ) {
                NotificationSoundPicker(
                    value: $needsYouNotificationSound,
                    allowsNone: true,
                    inheritsFlagSound: false,
                    accessibilityID: "SettingsNeedsYouSoundPicker"
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.notifications.flagSound.title", defaultValue: "Flag Sound"),
                subtitle: String(localized: "settings.notifications.flagSound.subtitleKinds", defaultValue: "Played when an agent raises a flag whose kind has no sound of its own. Flags always sound, at every notification level."),
                controlWidth: notificationSoundControlWidth
            ) {
                NotificationSoundPicker(
                    value: $flagNotificationSound,
                    allowsNone: false,
                    inheritsFlagSound: false,
                    accessibilityID: "SettingsFlagSoundPicker"
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.command", defaultValue: "Command"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.notifications.command.title", defaultValue: "Notification Command"),
                subtitle: String(localized: "settings.notifications.command.subtitle", defaultValue: "Runs with /bin/sh -c when notifications fire. Notification title, subtitle, and body are exposed as CMUX_NOTIFICATION_* env vars.")
            ) {
                TextField(
                    String(localized: "settings.notifications.command.placeholder", defaultValue: "say \"done\""),
                    text: $notificationCustomCommand
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }
    }

    @ViewBuilder
    private var inputSettingsPage: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.textBoxInput", defaultValue: "TextBox Input"))
            .id(SettingsNavigationTarget.textBoxInput)
            .accessibilityIdentifier("SettingsTextBoxInputSection")
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.textBoxInput.sendOnReturn", defaultValue: "Send on Return"),
                subtitle: String(localized: "settings.textBoxInput.sendOnReturn.subtitle", defaultValue: "Insert new line with Shift+Return"),
                controlWidth: pickerColumnWidth,
                selection: $textBoxEnterToSend
            ) {
                Text(String(localized: "settings.textBoxInput.sendOnReturn.on", defaultValue: "Return = Send")).tag(true)
                Text(String(localized: "settings.textBoxInput.sendOnReturn.off", defaultValue: "Return = Newline")).tag(false)
            }

            SettingsCardDivider()

            SettingsPickerRow(
                String(localized: "settings.textBoxInput.escapeBehavior", defaultValue: "Escape Key"),
                subtitle: String(localized: "settings.textBoxInput.escapeBehavior.subtitle", defaultValue: "Action when pressing Escape in the TextBox."),
                controlWidth: pickerColumnWidth,
                selection: $textBoxEscapeBehavior
            ) {
                ForEach(TextBoxEscapeBehavior.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsPickerRow(
                String(
                    format: String(localized: "settings.textBoxInput.shortcutBehavior", defaultValue: "Keyboard Shortcut (%@)"),
                    KeyboardShortcutSettings.shortcut(for: .toggleTextBoxInput).displayString
                ),
                subtitle: String(localized: "settings.textBoxInput.shortcutBehavior.subtitle", defaultValue: "Shortcut key can be changed in Keyboard Shortcuts settings."),
                controlWidth: pickerColumnWidth,
                selection: $textBoxShortcutBehavior
            ) {
                ForEach(TextBoxShortcutBehavior.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.commandPalette", defaultValue: "Command Palette"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.app.renameSelectsName", defaultValue: "Rename Selects Existing Name"),
                subtitle: commandPaletteRenameSelectAllOnFocus
                    ? String(localized: "settings.app.renameSelectsName.subtitleOn", defaultValue: "Command Palette rename starts with all text selected.")
                    : String(localized: "settings.app.renameSelectsName.subtitleOff", defaultValue: "Command Palette rename keeps the caret at the end.")
            ) {
                Toggle("", isOn: $commandPaletteRenameSelectAllOnFocus)
                    .labelsHidden()
                    .controlSize(.small)
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Panels"),
                subtitle: commandPaletteSearchAllSurfaces
                    ? String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOn", defaultValue: "Cmd+P also matches terminal, browser, and markdown panels across workspaces.")
                    : String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOff", defaultValue: "Cmd+P matches workspace rows only.")
            ) {
                Toggle("", isOn: $commandPaletteSearchAllSurfaces)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("CommandPaletteSearchAllSurfacesToggle")
                    .accessibilityLabel(
                        String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Panels")
                    )
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.shortcutHints", defaultValue: "Shortcut Hints"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.shortcuts.showHints", defaultValue: "Show Cmd/Ctrl-Hold Shortcut Hints"),
                subtitle: showShortcutHintsOnCommandHold
                    ? String(localized: "settings.shortcuts.showHints.subtitleOn", defaultValue: "Holding Cmd (sidebar/titlebar) or Ctrl/Cmd (panel bar) reveals shortcut hints.")
                    : String(localized: "settings.shortcuts.showHints.subtitleOff", defaultValue: "Holding Cmd or Ctrl keeps shortcut hint pills hidden.")
            ) {
                Toggle("", isOn: $showShortcutHintsOnCommandHold)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var keyboardShortcutSettingsPage: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"))
            .id(SettingsNavigationTarget.keyboardShortcuts)
            .accessibilityIdentifier("SettingsKeyboardShortcutsSection")
        SettingsCard {
            ForEach(Array(shortcutGroups.enumerated()), id: \.element.id) { groupIndex, group in
                if groupIndex > 0 {
                    SettingsCardDivider()
                }

                Text(group.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 7)

                SettingsCardDivider()

                ForEach(Array(group.actions.enumerated()), id: \.element.id) { index, action in
                    ShortcutSettingRow(action: action)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    if index < group.actions.count - 1 {
                        SettingsCardDivider()
                    }
                }
            }
        }
        .id(shortcutResetToken)

        Text(String(localized: "settings.shortcuts.recordHint", defaultValue: "Click a shortcut value to record a new shortcut."))
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.leading, 2)
            .accessibilityIdentifier("ShortcutRecordingHint")
    }

    // C11-14: Agents gets its own Settings page. c11 skills install first
    // (they're what makes the agents actually understand c11); default agent
    // controls what the per-pane A button launches.
    @ViewBuilder
    private var agentsSettingsPage: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.c11Skills", defaultValue: "c11 skills"))
        SettingsCardNote(String(
            localized: "settings.c11Skills.note",
            defaultValue: "c11's skill files install into each agent's skill folder (Claude Code, Codex, …) with your approval. linked folders are shown as shared so removing once cannot silently affect another agent."
        ))
        SettingsCard {
            AgentSkillsSettingsSection()
        }

        SettingsSectionHeader(title: String(
            localized: "settings.section.defaultAgent",
            defaultValue: "default agent"
        ))
        .id(SettingsNavigationTarget.agents)
        SettingsCardNote(String(
            localized: "settings.defaultAgent.projectChoicesNote",
            defaultValue: "the A button on every area launches this. new terminal still opens bash. a repo `.c11/agents.json` can pick the agent, model and effort for terminals opened there. the command, environment and prompts always come from these settings."
        ))
        SettingsCard {
            DefaultAgentSettingsSection()
        }

        SettingsSectionHeader(title: String(
            localized: "settings.section.flagKinds",
            defaultValue: "Flag kinds"
        ))
        SettingsCardNote(String(
            localized: "settings.flagKinds.note",
            defaultValue: "Named flags use a fixed color palette. Existing flags keep the display snapshot they had when raised. A kind with seconds set lowers its flags once you have looked at the panel that long."
        ))
        SettingsCard {
            PanelFlagKindSettingsSection()
        }

        // C11H-261: Waiting means waiting.
        SettingsSectionHeader(title: String(
            localized: "settings.section.waitingCheck",
            defaultValue: "Waiting check"
        ))
        SettingsCard {
            WaitingCheckSettingsSection()
        }
    }

    // C11-14: Automation page now hosts the permissions + socket-access +
    // integrations sections that used to share a page with Agents.
    @ViewBuilder
    private var automationSettingsPage: some View {
        SettingsSectionHeader(title: String(
            localized: "settings.section.permissions",
            defaultValue: "Permissions"
        ))
        SettingsCard {
            SettingsCardRow(
                String(
                    localized: "settings.tccPrimer.row.title",
                    defaultValue: "Permissions primer"
                ),
                subtitle: String(
                    localized: "settings.tccPrimer.row.subtitle",
                    defaultValue: "Re-open the explainer for macOS folder prompts. Covers why you see the dialogs, how to say no, and the Full Disk Access shortcut."
                )
            ) {
                Button(String(
                    localized: "settings.tccPrimer.showAgain",
                    defaultValue: "Show permissions primer…"
                )) {
                    (NSApp.delegate as? AppDelegate)?.presentTCCPrimer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.socketAccess", defaultValue: "Socket Access"))
        SettingsCard {
            SettingsPickerRow(
                String(localized: "settings.automation.socketMode", defaultValue: "Socket Control Mode"),
                subtitle: selectedSocketControlMode.description,
                controlWidth: pickerColumnWidth,
                selection: socketModeSelection,
                accessibilityId: "AutomationSocketModePicker"
            ) {
                ForEach(SocketControlMode.uiCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.socketMode.note", defaultValue: "Socket modes decide which local processes can drive c11. Automation and password modes widen access beyond c11-launched processes."))
            if selectedSocketControlMode == .password {
                SettingsCardDivider()
                SettingsCardRow(
                    String(localized: "settings.automation.socketPassword", defaultValue: "Socket Password"),
                    subtitle: hasSocketPasswordConfigured
                        ? String(localized: "settings.automation.socketPassword.subtitleSet", defaultValue: "Stored in Application Support.")
                        : String(localized: "settings.automation.socketPassword.subtitleUnset", defaultValue: "No password set. External clients will be blocked until one is configured.")
                ) {
                    HStack(spacing: 8) {
                        SecureField(String(localized: "settings.automation.socketPassword.placeholder", defaultValue: "Password"), text: $socketPasswordDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        Button(hasSocketPasswordConfigured ? String(localized: "settings.automation.socketPassword.change", defaultValue: "Change") : String(localized: "settings.automation.socketPassword.set", defaultValue: "Set")) {
                            saveSocketPassword()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasSocketPasswordConfigured {
                            Button(String(localized: "settings.automation.socketPassword.clear", defaultValue: "Clear")) {
                                clearSocketPassword()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                if let message = socketPasswordStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(socketPasswordStatusIsError ? Color.red : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
            if selectedSocketControlMode == .allowAll {
                SettingsCardDivider()
                Text(String(localized: "settings.automation.openAccessWarning", defaultValue: "Warning: Full open access makes the control socket world-readable/writable on this Mac and disables auth checks. Use only for local debugging."))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.agentIntegrations", defaultValue: "Agent Integrations"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.automation.claudeCode", defaultValue: "Claude Code Integration"),
                subtitle: claudeCodeHooksEnabled
                    ? String(localized: "settings.automation.claudeCode.subtitleOn", defaultValue: "Sidebar shows Claude session status and notifications.")
                    : String(localized: "settings.automation.claudeCode.subtitleOff", defaultValue: "Claude Code runs without c11 integration.")
            ) {
                Toggle("", isOn: $claudeCodeHooksEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsClaudeCodeHooksToggle")
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.claudeCode.note", defaultValue: "When enabled, c11 wraps the claude command to inject session tracking and notification hooks. Disable if you prefer to manage Claude Code hooks yourself."))
        }
    }

    @ViewBuilder
    private var dataPrivacySettingsPage: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.dataLeaving", defaultValue: "Data Leaving the Machine"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.app.telemetry", defaultValue: "Send anonymous telemetry"),
                subtitle: String(localized: "settings.dataPrivacy.telemetry.c11None", defaultValue: "c11 sends no telemetry.")
            ) {
                Toggle("", isOn: .constant(false))
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(true)
                    .accessibilityIdentifier("SettingsTelemetryToggle")
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.localActivityHistory", defaultValue: "Local activity history"))
        SettingsCard {
            SettingsCardNote(String(localized: "settings.activityHistory.localOnly", defaultValue: "Activity history stays on this Mac."))
            SettingsCardDivider()
            SettingsCardRow(
                String(localized: "settings.activityHistory.analytics", defaultValue: "Record usage analytics"),
                subtitle: String(localized: "settings.activityHistory.analytics.subtitle", defaultValue: "Record foreground, workspace, and app health events.")
            ) {
                Toggle("", isOn: $recordUsageAnalytics)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsActivityAnalyticsToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                String(localized: "settings.activityHistory.keepText", defaultValue: "Keep message and input text"),
                subtitle: String(localized: "settings.activityHistory.keepText.subtitle", defaultValue: "When off, new activity records keep byte counts only. Mailbox delivery still needs its local message files.")
            ) {
                Toggle("", isOn: $keepActivityText)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsActivityTextToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(String(localized: "settings.activityHistory.retention", defaultValue: "Keep history for")) {
                Picker("", selection: activityRetentionSelection) {
                    Text(String(localized: "settings.activityHistory.retention.7", defaultValue: "7 days")).tag(7)
                    Text(String(localized: "settings.activityHistory.retention.14", defaultValue: "14 days")).tag(14)
                    Text(String(localized: "settings.activityHistory.retention.30", defaultValue: "30 days")).tag(30)
                }
                .labelsHidden()
                .frame(width: pickerColumnWidth)
                .accessibilityIdentifier("SettingsActivityRetentionPicker")
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.localBrowserData", defaultValue: "Local Browser Data"))
        SettingsCard {
            SettingsCardRow(String(localized: "settings.browser.history", defaultValue: "Browsing History"), subtitle: browserHistorySubtitle) {
                Button(String(localized: "settings.browser.history.clearButton", defaultValue: "Clear History…")) {
                    showClearBrowserHistoryConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(browserHistoryEntryCount == 0)
            }
        }

        SettingsSectionHeader(title: String(localized: "settings.section.resetSettings", defaultValue: "Reset Settings"))
        SettingsCard {
            SettingsCardNote(String(localized: "settings.reset.coverage", defaultValue: "Resets language, app behavior, browser routing and import hints, notification preferences, sidebar details and tint, shortcuts, TextBox input, and workspace colors."))

            SettingsCardDivider()

            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "settings.reset.resetSettings", defaultValue: "Reset Settings")) {
                    resetAllSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }

        SettingsSectionHeader(title: String(localized: "settings.section.externalState", defaultValue: "External State Not Reset"))
        SettingsCard {
            SettingsCardNote(String(localized: "settings.reset.externalState", defaultValue: "Reset Settings does not clear c11 theme slots, port ranges, browser history, socket password files, agent skill install state, or macOS notification permission. Clear browser history above; change the rest where it lives."))
        }
    }

    @ViewBuilder
    private var advancedSettingsPage: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.ports", defaultValue: "Ports"))
        SettingsCard {
            SettingsCardRow(String(localized: "settings.automation.portBase", defaultValue: "Port Base"), subtitle: String(localized: "settings.automation.portBase.subtitle", defaultValue: "Starting port for CMUX_PORT env var."), controlWidth: pickerColumnWidth) {
                TextField("", value: $cmuxPortBase, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }

            SettingsCardDivider()

            SettingsCardRow(String(localized: "settings.automation.portRange", defaultValue: "Port Range Size"), subtitle: String(localized: "settings.automation.portRange.subtitle", defaultValue: "Number of ports per workspace."), controlWidth: pickerColumnWidth) {
                TextField("", value: $cmuxPortRange, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.port.note", defaultValue: "Each workspace gets CMUX_PORT and CMUX_PORT_END env vars with a dedicated port range. New terminals inherit these values."))
        }

        SettingsSectionHeader(title: String(localized: "settings.section.socketOverrides", defaultValue: "Socket Overrides"))
        SettingsCard {
            SettingsCardNote(String(localized: "settings.automation.socketOverrides.note", defaultValue: "Overrides: C11_SOCKET_ENABLE, C11_SOCKET_MODE, and C11_SOCKET_PATH (set C11_ALLOW_SOCKET_OVERRIDE=1 for stable/nightly builds)."))
        }
    }

    private var shortcutGroups: [ShortcutSettingsGroup] {
        [
            ShortcutSettingsGroup(
                id: "window",
                title: String(localized: "settings.shortcuts.group.window", defaultValue: "Window"),
                actions: [.toggleSidebar, .newWorkspace, .newWindow, .closeWindow, .openFolder]
            ),
            ShortcutSettingsGroup(
                id: "navigation",
                title: String(localized: "settings.shortcuts.group.navigation", defaultValue: "Navigation"),
                actions: [.nextSurface, .prevSurface, .nextSidebarWorkspace, .prevSidebarWorkspace, .focusHistoryBack, .focusHistoryForward, .renamePanel, .renameWorkspace, .closeWorkspace, .newSurface, .newAgent]
            ),
            ShortcutSettingsGroup(
                id: "panes",
                title: String(localized: "settings.shortcuts.group.panes", defaultValue: "Areas"),
                actions: [.focusLeft, .focusRight, .focusUp, .focusDown, .splitRight, .splitDown, .toggleSplitZoom, .splitBrowserRight, .splitBrowserDown]
            ),
            ShortcutSettingsGroup(
                id: "font",
                title: String(localized: "settings.shortcuts.group.font", defaultValue: "Font"),
                actions: [.globalFontIncrease, .globalFontDecrease, .globalFontReset]
            ),
            ShortcutSettingsGroup(
                id: "browser",
                title: String(localized: "settings.shortcuts.group.browser", defaultValue: "Browser"),
                actions: [.openBrowser, .toggleBrowserDeveloperTools, .showBrowserJavaScriptConsole]
            ),
            ShortcutSettingsGroup(
                id: "notifications",
                title: String(localized: "settings.shortcuts.group.notifications", defaultValue: "Notifications"),
                actions: [.showNotifications, .jumpToUnread, .triggerFlash]
            ),
            ShortcutSettingsGroup(
                id: "terminal",
                title: String(localized: "settings.shortcuts.group.terminal", defaultValue: "Terminal"),
                actions: [.toggleTerminalCopyMode]
            ),
            ShortcutSettingsGroup(
                id: "textBox",
                title: String(localized: "settings.shortcuts.group.textBox", defaultValue: "TextBox"),
                actions: [.toggleTextBoxInput]
            ),
            ShortcutSettingsGroup(
                id: "help",
                title: String(localized: "settings.shortcuts.group.help", defaultValue: "Help"),
                actions: [.sendFeedback]
            ),
        ]
    }

    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open -n -- \"$RELAUNCH_PATH\""]
        task.environment = ["RELAUNCH_PATH": bundlePath]
        do {
            try task.run()
        } catch {
            return
        }
        QuitConfirmationPolicy.armBypass()
        NSApplication.shared.terminate(nil)
    }

    private func resetAllSettings() {
        isResettingSettings = true
        appLanguage = LanguageSettings.defaultLanguage.rawValue
        LanguageSettings.apply(.system)
        if appLanguage != LanguageSettings.languageAtLaunch.rawValue {
            showLanguageRestartAlert = true
        }
        socketControlMode = SocketControlSettings.defaultMode.rawValue
        internalBrowserEnabled = PanelTypeAvailability.defaultEnabled
        markdownSurfacesEnabled = PanelTypeAvailability.defaultEnabled
        showSurfaceIdsInPanelTitles = PanelOrdinalDisplaySettings.defaultShowSurfaceIds
        askMachineForNewTerminals = MachinePickerSettings.defaultAsk
        showWorkspaceIdsInSidebar = WorkspaceOrdinalDisplaySettings.defaultShowWorkspaceIds
        panelLayoutMode = PanelLayoutSettings.defaultMode.rawValue
        launchResumePolicy = LaunchResumePolicy.always.rawValue
        massSignalEndAutoResume = false
        claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
        sendAnonymousTelemetry = TelemetrySettings.defaultSendAnonymousTelemetry
        recordUsageAnalytics = true
        keepActivityText = true
        activityRetentionDays = 14
        browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
        browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
        browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
        browserImportHintVariantRaw = BrowserImportHintSettings.defaultVariant.rawValue
        showBrowserImportHintOnBlankPanels = BrowserImportHintSettings.defaultShowOnBlankPanels
        isBrowserImportHintDismissed = BrowserImportHintSettings.defaultDismissed
        openTerminalLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenTerminalLinksInCmuxBrowser
        interceptTerminalOpenCommandInCmuxBrowser = BrowserLinkOpenSettings.defaultInterceptTerminalOpenCommandInCmuxBrowser
        browserHostWhitelist = BrowserLinkOpenSettings.defaultBrowserHostWhitelist
        browserExternalOpenPatterns = BrowserLinkOpenSettings.defaultBrowserExternalOpenPatterns
        browserExternalSchemeAllowlist = ""
        browserExternalSchemeAllowlistDraft = BrowserExternalSchemeAllowlistDraft(saved: "")
        browserInsecureHTTPAllowlist = BrowserInsecureHTTPSettings.defaultAllowlistText
        browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
        notificationSound = NotificationSoundSettings.defaultValue
        needsYouNotificationSound = NotificationSoundChannel.needsYou.shippedDefault.rawValue
        flagNotificationSound = FlagSoundSettings.defaultValue
        notificationCustomCommand = NotificationSoundSettings.defaultCustomCommand
        notificationPaneRingEnabled = NotificationAreaRingSettings.defaultEnabled
        notificationPaneFlashEnabled = NotificationAreaFlashSettings.defaultEnabled
        warnBeforeQuitShortcut = QuitWarningSettings.defaultWarnBeforeQuit
        keepTerminalsAfterQuit = QuitTerminalsSettings.defaultKeepTerminals
        commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
        commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
        ShortcutHintDebugSettings.resetVisibilityDefaults()
        alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
        newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
        attentionJumpOrderRaw = AttentionJumpOrder.defaultOrder.rawValue
        workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        closeWorkspaceOnLastSurfaceShortcut = LastPanelCloseShortcutSettings.defaultValue
        workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
        sidebarHideAllDetails = SidebarWorkspaceDetailSettings.defaultHideAllDetails
        sidebarShowNotificationMessage = SidebarWorkspaceDetailSettings.defaultShowNotificationMessage
        sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
        sidebarActiveWorkspaceIndicatorStyle = SidebarActiveWorkspaceIndicatorSettings.defaultStyle.rawValue
        sidebarShowBranchDirectory = true
        sidebarShowPullRequest = true
        openSidebarPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser
        showShortcutHintsOnCommandHold = ShortcutHintDebugSettings.defaultShowHintsOnCommandHold
        sidebarShowSSH = true
        sidebarShowPorts = true
        sidebarShowLog = true
        sidebarShowProgress = true
        sidebarShowMetadata = true
        defaults.removeObject(forKey: SidebarStalenessSettings.staleThresholdKey)
        defaults.removeObject(forKey: SidebarStalenessSettings.expiryThresholdKey)
        sidebarAgentColdThresholdSeconds = SidebarAgentColdSettings.defaultSeconds
        sidebarTintHex = SidebarTintDefaults.hex
        sidebarTintHexLight = nil
        sidebarTintHexDark = nil
        sidebarTintOpacity = SidebarTintDefaults.opacity
        showOpenAccessConfirmation = false
        pendingOpenAccessMode = nil
        socketPasswordDraft = ""
        socketPasswordStatusMessage = nil
        socketPasswordStatusIsError = false
        refreshDetectedImportBrowsers()
        KeyboardShortcutSettings.resetAll()
        // [TextBox] Also reset TextBox Input defaults when Reset All runs.
        TextBoxInputSettings.resetAll()
        textBoxEnterToSend = TextBoxInputSettings.defaultEnterToSend
        textBoxEscapeBehavior = TextBoxInputSettings.defaultEscapeBehavior.rawValue
        textBoxShortcutBehavior = TextBoxInputSettings.defaultShortcutBehavior.rawValue
        WorkspaceColorSettings.reset()
        shortcutResetToken = UUID()
        DispatchQueue.main.async { isResettingSettings = false }
    }

    private func saveBrowserExternalSchemeAllowlist() {
        browserExternalSchemeAllowlistDraft.save()
    }

    private func saveBrowserInsecureHTTPAllowlist() {
        browserInsecureHTTPAllowlist = browserInsecureHTTPAllowlistDraft
    }

    private func refreshDetectedImportBrowsers() {
        // C11-196: the detector probes a dozen browser bundle identifiers through
        // `NSWorkspace.urlForApplication(withBundleIdentifier:)`, each one a
        // synchronous XPC round trip to `launchservicesd`. Settings opened this
        // on the main thread from `.onAppear`; the browser panel's own empty-state
        // detector already runs it detached, so match that.
        Task {
            let browsers = await Task.detached(priority: .utility) {
                InstalledBrowserDetector.detectInstalledBrowsers()
            }.value
            await MainActor.run {
                detectedImportBrowsers = browsers
            }
        }
    }
}

private struct SettingsTopOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SettingsTitleLeadingInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let maxX = buttons
                .compactMap { window.standardWindowButton($0)?.frame.maxX }
                .max() ?? 78
            let nextInset = maxX + 14
            if abs(nextInset - inset) > 0.5 {
                inset = nextInset
            }
        }
    }
}

private struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.leading, 2)
            .padding(.bottom, -2)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: NSColor.controlBackgroundColor).opacity(0.76))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color(nsColor: NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                )
        )
    }
}

private struct SettingsCardRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat?
    @ViewBuilder let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let controlWidth {
                    trailing
                        .frame(width: controlWidth, alignment: .trailing)
                } else {
                    trailing
                }
            }
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsPickerRow<SelectionValue: Hashable, PickerContent: View, ExtraTrailing: View>: View {
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat
    @Binding var selection: SelectionValue
    let pickerContent: PickerContent
    let extraTrailing: ExtraTrailing
    let accessibilityId: String?

    init(
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat,
        selection: Binding<SelectionValue>,
        accessibilityId: String? = nil,
        @ViewBuilder content: () -> PickerContent,
        @ViewBuilder extraTrailing: () -> ExtraTrailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self._selection = selection
        self.pickerContent = content()
        self.extraTrailing = extraTrailing()
        self.accessibilityId = accessibilityId
    }

    var body: some View {
        SettingsCardRow(title, subtitle: subtitle, controlWidth: controlWidth) {
            HStack(spacing: 6) {
                Picker("", selection: $selection) {
                    pickerContent
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .applyIf(accessibilityId != nil) { $0.accessibilityIdentifier(accessibilityId!) }
                extraTrailing
            }
        }
    }
}

extension SettingsPickerRow where ExtraTrailing == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat,
        selection: Binding<SelectionValue>,
        accessibilityId: String? = nil,
        @ViewBuilder content: () -> PickerContent
    ) {
        self.init(title, subtitle: subtitle, controlWidth: controlWidth, selection: selection, accessibilityId: accessibilityId, content: content) {
            EmptyView()
        }
    }
}

/// C11H-126: the editor for one machine's roster entry, shown by the gear
/// beside it on the Herder Topography map.
struct MachineRosterSettingsRow: View {
    let row: MachineRosterRow
    let onSave: (String, String, String) -> Void
    let onRemove: (String) -> Void
    var hcNote: String? = nil
    /// Whether the note's row offers Update… (a machine refused for anything
    /// but a missing core id can only be removed; C11H-359).
    var offersUpdate = true
    var onUpdate: () -> Void = {}
    var onRemoveMachine: () -> Void = {}
    /// C11H-391: the note's button reads "Link Again…" when only c11h's
    /// link of this name exists (it opens Add Machine, consent first).
    var linksAgain = false
    /// C11H-391: c11h's old link of this name beside c11's own; removing it
    /// ends only c11h's terminals there.
    var onRemoveC11hLink: (() -> Void)?

    @State private var name: String
    @State private var hex: String

    init(row: MachineRosterRow, onSave: @escaping (String, String, String) -> Void, onRemove: @escaping (String) -> Void,
         hcNote: String? = nil, offersUpdate: Bool = true, onUpdate: @escaping () -> Void = {},
         onRemoveMachine: @escaping () -> Void = {}, linksAgain: Bool = false,
         onRemoveC11hLink: (() -> Void)? = nil) {
        self.row = row
        self.onSave = onSave
        self.onRemove = onRemove
        self.hcNote = hcNote
        self.offersUpdate = offersUpdate
        self.onUpdate = onUpdate
        self.onRemoveMachine = onRemoveMachine
        self.linksAgain = linksAgain
        self.onRemoveC11hLink = onRemoveC11hLink
        _name = State(initialValue: row.entry?.name ?? "")
        _hex = State(initialValue: row.entry?.color ?? "")
    }

    private var stateLabel: String {
        if row.isLocal {
            return String(localized: "settings.machines.state.thisMac", defaultValue: "This Mac")
        }
        guard row.linked else {
            return String(localized: "settings.machines.state.notLinked", defaultValue: "Not linked")
        }
        return row.connected == true
            ? String(localized: "settings.machines.state.connected", defaultValue: "Connected")
            : String(localized: "settings.machines.state.disconnected", defaultValue: "Disconnected")
    }

    private var colorBinding: Binding<Color> {
        Binding(
            // An unset color starts opaque: the picker keeps the current
            // opacity, so a faint placeholder would make every first pick faint.
            get: { MachineRosterColor.nsColor(hex).map { Color(nsColor: $0) } ?? Color(nsColor: .systemGray) },
            set: { picked in
                if let value = MachineRosterColor.hex(from: NSColor(picked)) { hex = value }
            }
        )
    }

    private var isDirty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != (row.entry?.name ?? "")
            || (MachineRosterColor.normalized(hex) ?? hex.trimmingCharacters(in: .whitespacesAndNewlines)) != (row.entry?.color ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(row.linked ? Color.secondary : Color.orange)
                if let hcNote {
                    Text(hcNote)
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .accessibilityIdentifier("SettingsMachineNeedsUpdate.\(row.id)")
                }
                Spacer(minLength: 8)
                if hcNote != nil, offersUpdate {
                    Button(linksAgain
                           ? String(localized: "settings.machines.linkAgain", defaultValue: "Link Again…")
                           : String(localized: "settings.machines.update", defaultValue: "Update…"), action: onUpdate)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("SettingsMachineUpdate.\(row.id)")
                }
                if let onRemoveC11hLink {
                    Button(String(localized: "settings.machines.removeC11hLink", defaultValue: "Remove c11h's Link…"),
                           action: onRemoveC11hLink)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("SettingsMachineRemoveC11hLink.\(row.id)")
                }
                if row.linked && !row.isLocal {
                    Button(String(localized: "settings.machines.removeMachine", defaultValue: "Remove…"), action: onRemoveMachine)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("SettingsMachineRemoveMachine.\(row.id)")
                }
            }
            HStack(spacing: 7) {
                TextField(row.defaultName, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120)
                    .accessibilityLabel(String(localized: "settings.machines.name", defaultValue: "Name"))
                    .accessibilityIdentifier("SettingsMachineName.\(row.id)")
                    .onSubmit { onSave(row.id, name, hex) }
                ColorPicker(String(localized: "settings.machines.color", defaultValue: "Color"), selection: colorBinding, supportsOpacity: true)
                    .labelsHidden()
                    .accessibilityIdentifier("SettingsMachineColor.\(row.id)")
                TextField(String(localized: "settings.machines.hexPlaceholder", defaultValue: "#RRGGBB"), text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 96)
                    .accessibilityLabel(String(localized: "settings.machines.hex", defaultValue: "Hex color"))
                    .accessibilityIdentifier("SettingsMachineHex.\(row.id)")
                    .onSubmit { onSave(row.id, name, hex) }
                Button(String(localized: "settings.machines.save", defaultValue: "Save")) {
                    onSave(row.id, name, hex)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isDirty)
                .accessibilityIdentifier("SettingsMachineSave.\(row.id)")
                Button(row.linked
                    ? String(localized: "settings.machines.resetButton", defaultValue: "Reset")
                    : String(localized: "settings.machines.remove", defaultValue: "Remove")) {
                    onRemove(row.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(row.entry == nil)
                .accessibilityIdentifier("SettingsMachineReset.\(row.id)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // Only a stored change to a field resets that field; a line going up
        // or down, or a change to the other field, keeps an edit in progress.
        .onChange(of: row.entry?.name) { updated in name = updated ?? "" }
        .onChange(of: row.entry?.color) { updated in hex = updated ?? "" }
    }
}

/// C11H-261: the waiting check's switches, the Jev key and Jev's health.
/// Every write happens on main (a SwiftUI action). A toggle posts
/// `.waitingCheckConfigurationDidChange` so the judge and the sidebar re-read;
/// the key store posts `.jevKeyDidChange`.
private struct WaitingCheckSettingsSection: View {
    @AppStorage(WaitingCheckSettings.enabledKey) private var enabled = true
    @AppStorage(WaitingCheckSettings.showDoneButtonKey) private var showDoneButton = true
    @AppStorage(WaitingCheckSettings.jevEnabledKey) private var jevEnabled = true
    @AppStorage(WaitingCheckSettings.withheldTermsKey) private var withheldTerms = ""
    @ObservedObject private var judge = WaitingCheckJudge.shared

    @State private var keyDraft = ""
    @State private var keyStoredInFile = false
    @State private var keyFromEnvironment = false
    @State private var keyStatusMessage: String?
    /// The withheld-terms editor writes here; the setting is committed on
    /// focus loss, on leaving Settings, or 1 s after the last keystroke.
    @State private var termsDraft = ""
    @State private var termsCommit: DispatchWorkItem?
    @FocusState private var termsFocused: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var keyStateText: String {
        if keyStoredInFile {
            return String(localized: "settings.waitingCheck.jevKey.saved", defaultValue: "Key saved")
        }
        if keyFromEnvironment {
            return String(localized: "settings.waitingCheck.jevKey.environment", defaultValue: "Using TYPESAFE_API_KEY from the environment")
        }
        return String(localized: "settings.waitingCheck.jevKey.none", defaultValue: "No key")
    }

    private var healthText: String {
        switch judge.jevHealth {
        case .off:
            return String(localized: "settings.waitingCheck.jevHealth.off", defaultValue: "Off")
        case .noKey:
            return String(localized: "settings.waitingCheck.jevHealth.noKey", defaultValue: "No key: the Needs you convention still runs")
        case .live:
            return String(localized: "settings.waitingCheck.jevHealth.live", defaultValue: "Live")
        case .failing(let since, let reason):
            let time = Self.timeFormatter.string(from: since)
            return String(localized: "settings.waitingCheck.jevHealth.failing", defaultValue: "Failing since \(time): \(reason)")
        }
    }

    private var healthIsFailing: Bool {
        if case .failing = judge.jevHealth { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCardRow(String(localized: "settings.waitingCheck.enabled", defaultValue: "Sort finished agents out of Waiting")) {
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsWaitingCheckEnabledToggle")
            }
            SettingsCardNote(String(
                localized: "settings.waitingCheck.enabled.note",
                defaultValue: "Reads each agent's latest reply when its turn ends. A reply whose “Needs you:” line says nothing is finished, not waiting."
            ))

            SettingsCardDivider()

            SettingsCardRow(String(localized: "settings.waitingCheck.showDoneButton", defaultValue: "Show the Done button")) {
                Toggle("", isOn: $showDoneButton)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!enabled)
                    .accessibilityIdentifier("SettingsWaitingCheckShowDoneToggle")
            }

            SettingsCardDivider()

            Text(String(localized: "settings.waitingCheck.jev.heading", defaultValue: "Jev"))
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 10)

            SettingsCardRow(String(localized: "settings.waitingCheck.jevEnabled", defaultValue: "Ask Jev when the reply doesn't say")) {
                Toggle("", isOn: $jevEnabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!enabled)
                    .accessibilityIdentifier("SettingsWaitingCheckJevToggle")
            }

            SettingsCardRow(
                String(localized: "settings.waitingCheck.jevKey", defaultValue: "TypeSafe API key"),
                subtitle: keyStateText
            ) {
                HStack(spacing: 8) {
                    SecureField(String(localized: "settings.waitingCheck.jevKey.placeholder", defaultValue: "API key"), text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .accessibilityIdentifier("SettingsWaitingCheckJevKeyField")
                    Button(String(localized: "settings.waitingCheck.jevKey.save", defaultValue: "Save")) {
                        saveKey()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("SettingsWaitingCheckJevKeySave")
                    if keyStoredInFile {
                        Button(String(localized: "settings.waitingCheck.jevKey.remove", defaultValue: "Remove")) {
                            removeKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("SettingsWaitingCheckJevKeyRemove")
                    }
                }
            }
            if let keyStatusMessage {
                Text(keyStatusMessage)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            SettingsCardRow(String(localized: "settings.waitingCheck.jevHealth", defaultValue: "Jev status")) {
                Text(healthText)
                    .font(.caption)
                    .foregroundStyle(healthIsFailing ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 280, alignment: .trailing)
                    .accessibilityIdentifier("SettingsWaitingCheckJevHealth")
            }

            SettingsCardNote(String(
                localized: "settings.waitingCheck.jev.note",
                defaultValue: "Jev reads the end of the agent's screen. With a key set, that text is sent to TypeSafe."
            ))

            SettingsCardDivider()

            VStack(alignment: .leading, spacing: 6) {
                SettingsCardRow(
                    String(localized: "settings.waitingCheck.withheldTerms", defaultValue: "Withhold lines containing"),
                    subtitle: String(localized: "settings.waitingCheck.withheldTerms.subtitle", defaultValue: "One term per line. A screen line containing any of them is never sent to Jev.")
                ) {
                    EmptyView()
                }

                TextEditor(text: $termsDraft)
                    .focused($termsFocused)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("SettingsWaitingCheckWithheldTerms")
            }
        }
        .onAppear {
            refreshKeyState()
            termsDraft = withheldTerms
        }
        .onDisappear(perform: commitTerms)
        .onChange(of: enabled) { _ in postChange() }
        .onChange(of: showDoneButton) { _ in postChange() }
        .onChange(of: jevEnabled) { _ in postChange() }
        .onChange(of: termsDraft) { _ in scheduleTermsCommit() }
        .onChange(of: termsFocused) { focused in
            if !focused { commitTerms() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .jevKeyDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            refreshKeyState()
        }
    }

    private func scheduleTermsCommit() {
        termsCommit?.cancel()
        let work = DispatchWorkItem { commitTerms() }
        termsCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The judge reads the terms when it builds a Jev call, so committing
    /// needs no notification.
    private func commitTerms() {
        termsCommit?.cancel()
        termsCommit = nil
        if withheldTerms != termsDraft { withheldTerms = termsDraft }
    }

    private func refreshKeyState() {
        let inFile = JevKeyStore.isStoredInFile
        keyStoredInFile = inFile
        keyFromEnvironment = !inFile && JevKeyStore.hasKey
    }

    private func saveKey() {
        if JevKeyStore.save(keyDraft) {
            keyDraft = ""
            keyStatusMessage = nil
        } else {
            keyStatusMessage = String(localized: "settings.waitingCheck.jevKey.saveFailed", defaultValue: "Could not save the key.")
        }
        refreshKeyState()
    }

    private func removeKey() {
        JevKeyStore.clear()
        keyStatusMessage = nil
        refreshKeyState()
    }

    /// Settings actions run on main; the post keeps listeners on main too.
    private func postChange() {
        NotificationCenter.default.post(name: .waitingCheckConfigurationDidChange, object: nil)
    }
}

private struct PanelFlagKindSettingsSection: View {
    @State private var kinds = PanelFlagKindRegistry.shared.all()
    @State private var newID = ""
    @State private var newName = ""
    @State private var newColor: PanelFlagColorToken = .green
    @State private var newEmoji = ""
    @State private var newEvaporateSeconds = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var canAdd: Bool {
        let candidate = PanelFlagKind(
            id: newID,
            name: newName,
            color: newColor,
            emoji: newEmoji.isEmpty ? nil : newEmoji,
            evaporateSeconds: Self.parseEvaporateSeconds(newEvaporateSeconds)
        )
        return candidate.isValid && !kinds.contains(where: { $0.id == candidate.id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element.id) { index, kind in
                PanelFlagKindSettingsRow(
                    kind: kind,
                    onSave: save,
                    onRemove: remove
                )
                if index < kinds.count - 1 { SettingsCardDivider() }
            }

            if !kinds.isEmpty { SettingsCardDivider() }

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "settings.flagKinds.addHeading", defaultValue: "Add a kind"))
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 7) {
                    TextField(String(localized: "settings.flagKinds.idPlaceholder", defaultValue: "slug"), text: $newID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 112)
                        .accessibilityIdentifier("SettingsFlagKindNewID")
                    TextField(String(localized: "settings.flagKinds.namePlaceholder", defaultValue: "Name"), text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 100)
                        .accessibilityIdentifier("SettingsFlagKindNewName")
                    colorPicker(selection: $newColor)
                    TextField(String(localized: "settings.flagKinds.emojiPlaceholder", defaultValue: "Emoji"), text: $newEmoji)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .accessibilityIdentifier("SettingsFlagKindNewEmoji")
                    HStack(spacing: 3) {
                        TextField(
                            String(localized: "settings.flagKinds.evaporatePlaceholder", defaultValue: "Never"),
                            text: $newEvaporateSeconds
                        )
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .frame(width: 56)
                        .accessibilityLabel(String(localized: "settings.flagKinds.evaporate", defaultValue: "Evaporate after seconds"))
                        .accessibilityIdentifier("SettingsFlagKindNewEvaporate")
                        Text(String(localized: "settings.flagKinds.secondsUnit", defaultValue: "s"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help(String(
                        localized: "settings.flagKinds.evaporateHelp",
                        defaultValue: "Lower this kind's flags after you look at the flagged panel for this many seconds (1 to 600). Leave blank to keep them until lowered."
                    ))
                    Button(String(localized: "settings.flagKinds.add", defaultValue: "Add"), action: add)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canAdd)
                        .accessibilityIdentifier("SettingsFlagKindAdd")
                }
                Text(String(localized: "settings.flagKinds.slugHelp", defaultValue: "Use a lowercase slug with letters, numbers, and single hyphens."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: PanelFlagKindRegistry.didChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in reload() }
    }

    private func colorPicker(selection: Binding<PanelFlagColorToken>) -> some View {
        Picker(String(localized: "settings.flagKinds.color", defaultValue: "Color"), selection: selection) {
            ForEach(PanelFlagColorToken.allCases, id: \.self) { token in
                Text(token.localizedName).tag(token)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private func reload() {
        kinds = PanelFlagKindRegistry.shared.all()
    }

    private func add() {
        save(PanelFlagKind(
            id: newID,
            name: newName,
            color: newColor,
            emoji: newEmoji.isEmpty ? nil : newEmoji,
            evaporateSeconds: Self.parseEvaporateSeconds(newEvaporateSeconds)
        ))
        if statusIsError == false {
            newID = ""
            newName = ""
            newEmoji = ""
            newEvaporateSeconds = ""
        }
    }

    /// Blank never evaporates. Anything that isn't 1...600 maps to 0, which the
    /// registry refuses, so the form shows its error instead of dropping it.
    static func parseEvaporateSeconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return PanelFlagKind.parseEvaporateSecondsArgument(trimmed) ?? 0
    }

    private func save(_ kind: PanelFlagKind) {
        do {
            try PanelFlagKindRegistry.shared.set(kind)
            reload()
            statusMessage = String(localized: "settings.flagKinds.saved", defaultValue: "Flag kind saved.")
            statusIsError = false
        } catch {
            statusMessage = String(localized: "settings.flagKinds.saveError", defaultValue: "Could not save this flag kind.")
            statusIsError = true
        }
    }

    private func remove(_ id: String) {
        do {
            _ = try PanelFlagKindRegistry.shared.remove(id: id)
            NotificationSoundPlayback.syncInBackground()
            reload()
            statusMessage = PanelFlagKindRegistry.isBuiltIn(id)
                ? String(localized: "settings.flagKinds.reset", defaultValue: "Built-in kind reset to its default.")
                : String(localized: "settings.flagKinds.removed", defaultValue: "Flag kind removed.")
            statusIsError = false
        } catch {
            statusMessage = String(localized: "settings.flagKinds.removeError", defaultValue: "Could not update this flag kind.")
            statusIsError = true
        }
    }
}

private struct PanelFlagKindSettingsRow: View {
    let kind: PanelFlagKind
    let onSave: (PanelFlagKind) -> Void
    let onRemove: (String) -> Void

    @State private var name: String
    @State private var color: PanelFlagColorToken
    @State private var emoji: String
    /// C11H-319: the kind's own sound; "" is the flag sound. Applied on change.
    @State private var sound: String
    /// C11H-330: whole seconds, blank for never.
    @State private var evaporateSeconds: String

    /// When this kind was last raised and how often (C11H-226), so unused
    /// kinds are easy to spot and prune.
    private var usageText: String {
        guard let usage = PanelFlagKindRegistry.shared.usage(id: kind.id) else {
            return String(localized: "settings.flagKinds.neverRaised", defaultValue: "Never raised")
        }
        let when = usage.lastRaisedAt.formatted(date: .abbreviated, time: .shortened)
        let count = usage.raiseCount
        return String(localized: "settings.flagKinds.lastRaised", defaultValue: "Last raised \(when) (\(count)×)")
    }

    init(kind: PanelFlagKind, onSave: @escaping (PanelFlagKind) -> Void, onRemove: @escaping (String) -> Void) {
        self.kind = kind
        self.onSave = onSave
        self.onRemove = onRemove
        _name = State(initialValue: kind.name)
        _color = State(initialValue: kind.color)
        _emoji = State(initialValue: kind.emoji ?? "")
        _sound = State(initialValue: PanelFlagKindRegistry.shared.sound(id: kind.id)?.rawValue ?? "")
        _evaporateSeconds = State(initialValue: kind.evaporateSeconds.map(String.init) ?? "")
    }

    private var parsedEvaporateSeconds: Int? {
        PanelFlagKindSettingsSection.parseEvaporateSeconds(evaporateSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(kind.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(usageText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("SettingsFlagKindUsage.\(kind.id)")
            }
            HStack(spacing: 7) {
                TextField(String(localized: "settings.flagKinds.namePlaceholder", defaultValue: "Name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100)
                    .accessibilityLabel(String(localized: "settings.flagKinds.name", defaultValue: "Name"))
                Picker(String(localized: "settings.flagKinds.color", defaultValue: "Color"), selection: $color) {
                    ForEach(PanelFlagColorToken.allCases, id: \.self) { token in
                        Text(token.localizedName).tag(token)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                TextField(String(localized: "settings.flagKinds.emojiPlaceholder", defaultValue: "Emoji"), text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .accessibilityLabel(String(localized: "settings.flagKinds.emoji", defaultValue: "Emoji"))
                HStack(spacing: 3) {
                    TextField(
                        String(localized: "settings.flagKinds.evaporatePlaceholder", defaultValue: "Never"),
                        text: $evaporateSeconds
                    )
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 56)
                    .accessibilityLabel(String(localized: "settings.flagKinds.evaporate", defaultValue: "Evaporate after seconds"))
                    .accessibilityIdentifier("SettingsFlagKindEvaporate.\(kind.id)")
                    Text(String(localized: "settings.flagKinds.secondsUnit", defaultValue: "s"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(String(
                    localized: "settings.flagKinds.evaporateHelp",
                    defaultValue: "Lower this kind's flags after you look at the flagged panel for this many seconds (1 to 600). Leave blank to keep them until lowered."
                ))
                Button(String(localized: "settings.flagKinds.save", defaultValue: "Save")) {
                    onSave(PanelFlagKind(
                        id: kind.id,
                        name: name,
                        color: color,
                        emoji: emoji.isEmpty ? nil : emoji,
                        evaporateSeconds: parsedEvaporateSeconds
                    ))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsFlagKindSave.\(kind.id)")
                Button(PanelFlagKindRegistry.isBuiltIn(kind.id)
                    ? String(localized: "settings.flagKinds.resetButton", defaultValue: "Reset")
                    : String(localized: "settings.flagKinds.remove", defaultValue: "Remove")) {
                    onRemove(kind.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsFlagKindRemove.\(kind.id)")
            }
            HStack(spacing: 7) {
                Text(String(localized: "settings.flagKinds.sound", defaultValue: "Sound"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NotificationSoundPicker(
                    value: $sound,
                    allowsNone: true,
                    inheritsFlagSound: true,
                    accessibilityID: "SettingsFlagKindSound.\(kind.id)"
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .onChange(of: kind) { updated in
            name = updated.name
            color = updated.color
            emoji = updated.emoji ?? ""
            evaporateSeconds = updated.evaporateSeconds.map(String.init) ?? ""
        }
        .onChange(of: sound) { updated in
            let choice = updated.isEmpty ? nil : NotificationSoundChoice(rawValue: updated)
            guard choice != PanelFlagKindRegistry.shared.sound(id: kind.id) else { return }
            try? PanelFlagKindRegistry.shared.setSound(id: kind.id, choice)
            NotificationSoundPlayback.syncInBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: PanelFlagKindRegistry.didChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in
            let current = PanelFlagKindRegistry.shared.sound(id: kind.id)?.rawValue ?? ""
            if current != sound { sound = current }
        }
    }
}

/// C11H-319: one sound picker for a channel or a flag kind: macOS sounds,
/// imported files, and Choose File to import another
/// (copied into c11's sound store). For a kind, the first entry is the flag
/// sound (an empty value).
private struct NotificationSoundPicker: View {
    @Binding var value: String
    let allowsNone: Bool
    let inheritsFlagSound: Bool
    let accessibilityID: String

    @State private var importedIDs: [String] = []
    @State private var importError: String?
    @State private var importing = false

    private var store: CustomNotificationSoundStore { .shared }

    /// A chosen file that is no longer in the store still shows, so the
    /// operator sees what falls back.
    private var missingFileValue: String? {
        guard value.hasPrefix(NotificationSoundChoice.filePrefix) else { return nil }
        let id = String(value.dropFirst(NotificationSoundChoice.filePrefix.count))
        return importedIDs.contains(id) ? nil : value
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Picker("", selection: $value) {
                    if inheritsFlagSound {
                        Text(String(localized: "notificationSound.choice.flagSound", defaultValue: "Flag Sound")).tag("")
                    }
                    if allowsNone {
                        Text(String(localized: "notificationSound.choice.none", defaultValue: "None")).tag("none")
                    }
                    Text(String(localized: "notificationSound.choice.default", defaultValue: "Default")).tag("default")
                    Divider()
                    ForEach(NotificationSoundCatalog.systemNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if !importedIDs.isEmpty {
                        Divider()
                        ForEach(importedIDs, id: \.self) { id in
                            Text(store.displayName(for: id) ?? id).tag(NotificationSoundChoice.file(id).rawValue)
                        }
                    }
                    if let missingFileValue {
                        Text(String(localized: "notificationSound.choice.missingFile", defaultValue: "Missing file")).tag(missingFileValue)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier(accessibilityID)
                Button {
                    preview()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(value == "none")
                .accessibilityIdentifier("\(accessibilityID).Preview")
                Button(String(localized: "notificationSound.chooseFile", defaultValue: "Choose File…")) {
                    chooseFile()
                }
                .controlSize(.small)
                .disabled(importing)
                .accessibilityIdentifier("\(accessibilityID).ChooseFile")
            }
            if let importError {
                Text(importError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 300, alignment: .trailing)
            }
        }
        .onAppear { importedIDs = store.importedIDs() }
        // A file imported elsewhere (another picker, the CLI) or a value set
        // from the CLI shows here without reopening Settings.
        .onChange(of: value) { _ in importedIDs = store.importedIDs() }
        .onReceive(NotificationCenter.default.publisher(for: CustomNotificationSoundStore.didImportNotification)) { _ in
            importedIDs = store.importedIDs()
        }
    }

    private func preview() {
        let choice = value.isEmpty
            ? NotificationSoundChannel.flag.choice(defaults: .standard)
            : NotificationSoundChoice(rawValue: value)
        guard let choice else { return }
        NotificationSoundSettings.previewSound(choice, store: store)
    }

    /// Runs right after the operator's click; the import runs off main.
    private func chooseFile() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [.audio]
        openPanel.title = String(
            localized: "settings.notifications.sound.custom.choose.title",
            defaultValue: "Choose Notification Sound"
        )
        openPanel.prompt = String(
            localized: "settings.notifications.sound.custom.choose.prompt",
            defaultValue: "Choose"
        )
        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }
        importing = true
        importError = nil
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let result = store.importSound(from: url)
            DispatchQueue.main.async {
                importing = false
                switch result {
                case .success(let id):
                    importedIDs = store.importedIDs()
                    value = NotificationSoundChoice.file(id).rawValue
                    NotificationSoundSettings.previewSound(.file(id), store: store)
                case .failure(let error):
                    importError = String(
                        localized: "notificationSound.importFailed",
                        defaultValue: "Couldn't use this file: \(error.message)"
                    )
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func applyIf(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

private struct SettingsCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: NSColor.separatorColor).opacity(0.5))
            .frame(height: 1)
    }
}

private struct SettingsCardNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum SettingsScrollAnchor {
    static let pageTop = "settings.page.top"
}

private struct SettingsSidebar: View {
    let selectedPage: SettingsPage
    let onSelect: (SettingsPage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "settings.title", defaultValue: "c11 Settings"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.92))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            ForEach(SettingsPage.allCases) { page in
                Button {
                    onSelect(page)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: page.iconName)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20)
                        Text(page.title)
                            .font(.system(size: 14, weight: selectedPage == page ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selectedPage == page ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selectedPage == page ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.title)
                .accessibilityIdentifier("settings.sidebar.\(page.rawValue)")
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 48)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.66))
    }
}

private struct ShortcutSettingRow: View {
    let action: KeyboardShortcutSettings.Action
    @State private var shortcut: StoredShortcut

    init(action: KeyboardShortcutSettings.Action) {
        self.action = action
        _shortcut = State(initialValue: KeyboardShortcutSettings.shortcut(for: action))
    }

    var body: some View {
        KeyboardShortcutRecorder(label: action.label, action: action, shortcut: $shortcut)
            .onChange(of: shortcut) { newValue in
                // A change that arrived by notification is already stored; writing it
                // back would pin a reset action to today's default as a custom value.
                guard newValue != KeyboardShortcutSettings.shortcut(for: action) else { return }
                KeyboardShortcutSettings.setShortcut(newValue, for: action)
            }
            .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
                let latest = KeyboardShortcutSettings.shortcut(for: action)
                if latest != shortcut {
                    shortcut = latest
                }
            }
    }
}

private struct SettingsRootView: View {
    var body: some View {
        SettingsView()
            .background(WindowAccessor { window in
                configureSettingsWindow(window)
            })
    }

    private func configureSettingsWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("cmux.settings")
        applyCurrentSettingsWindowStyle(to: window)

        let accessories = window.titlebarAccessoryViewControllers
        for index in accessories.indices.reversed() {
            guard let identifier = accessories[index].view.identifier?.rawValue else { continue }
            guard identifier.hasPrefix("cmux.") else { continue }
            window.removeTitlebarAccessoryViewController(at: index)
        }
        AppDelegate.shared?.applyWindowDecorations(to: window)
    }

    private func applyCurrentSettingsWindowStyle(to window: NSWindow) {
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .settings)
    }
}

/// Ticket 12: File > New Terminal on <Machine>, one item per added machine,
/// disabled while that machine's link is down.
struct RemoteTerminalMenuItems: View {
    @ObservedObject var directory = HCMachineDirectory.shared
    let open: (String) -> Void

    var body: some View {
        if !directory.entries.isEmpty {
            Divider()
            ForEach(directory.entries) { entry in
                Button(entry.title) { open(entry.machine) }
                    .disabled(!entry.connected || !entry.usable)
            }
        }
    }
}
