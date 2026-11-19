import AppKit
import SwiftUI

// c11 (C11H-197): window names, window themes, display geometry and window
// placement. Coordinates follow `WindowPlacement.swift`: global points,
// top-left origin at the main display's top-left, y down.

/// A main window's identity, theme and geometry at one moment.
struct MainWindowGeometry {
    let windowId: UUID
    let windowNumber: Int?
    let name: String?
    let themeOverride: String?
    let effectiveTheme: String
    /// Top-left global points; nil when the window has no AppKit window yet.
    let frame: CGRect?
    let display: DisplayGeometry?
    let isKey: Bool
    let isMain: Bool
    let isMinimized: Bool
    let isFullScreen: Bool
    let isOnActiveSpace: Bool
    let isVisible: Bool

    var frameOnDisplay: CGRect? {
        guard let frame, let display else { return nil }
        return DisplayArrangement.frameOnDisplay(frame, display: display)
    }

    var visibleFraction: Double? {
        guard let frame, let display else { return nil }
        return DisplayArrangement.visibleFraction(of: frame, on: display)
    }
}

/// The primary window's UUID across launches. SwiftUI creates the primary
/// window before the session restores, so it takes the UUID of the first window
/// in the last saved snapshot, which is the entry that restores onto it.
enum PrimaryWindowIdentity {
    static let defaultsKey = "c11.window.primaryWindowId"

    static func launchWindowId(defaults: UserDefaults = .standard) -> UUID {
        defaults.string(forKey: defaultsKey).flatMap(UUID.init(uuidString:)) ?? UUID()
    }

    static func remember(_ windowId: String?, defaults: UserDefaults = .standard) {
        guard let windowId, UUID(uuidString: windowId) != nil,
              defaults.string(forKey: defaultsKey) != windowId else { return }
        defaults.set(windowId, forKey: defaultsKey)
    }
}

extension AppSessionSnapshot {
    /// The entry saved with `windowId` moved first, other entries in order.
    /// The primary window exists (with that UUID) before the session restores,
    /// and the first entry restores onto it.
    func primaryFirst(windowId: UUID) -> AppSessionSnapshot {
        guard let index = windows.firstIndex(where: { $0.windowId.flatMap(UUID.init(uuidString:)) == windowId }),
              index > 0 else { return self }
        var copy = self
        let entry = copy.windows.remove(at: index)
        copy.windows.insert(entry, at: 0)
        return copy
    }
}

/// Socket payload shapes shared by `window.list`, `system.tree`, `system.identify`,
/// `display.list` and the `display.changed` / `window.moved` events.
enum WindowGeometryPayload {
    /// Names the convention in every geometry reply, so a reader needs no doc.
    static let coordinateSpace = "global points, origin at the main display's top-left, y down"

    // The display UUID is `uuid`, not `id`: the CLI's default ref-only
    // output drops an `id` that sits beside a `ref`.
    static func displayRef(_ display: DisplayGeometry?) -> Any {
        guard let display else { return NSNull() }
        return [
            "uuid": display.uuid ?? NSNull(),
            "display_id": Int(display.displayID),
            "ref": display.ref,
            "index": display.index,
            "name": display.name,
        ] as [String: Any]
    }

    static func display(_ display: DisplayGeometry) -> [String: Any] {
        [
            "uuid": display.uuid ?? NSNull(),
            "display_id": Int(display.displayID),
            "ref": display.ref,
            "index": display.index,
            "name": display.name,
            "main": display.isMain,
            "builtin": display.isBuiltin,
            "frame": display.frame.c11Payload,
            "visible_frame": display.visibleFrame.c11Payload,
            "scale": Double(display.scale),
        ]
    }

    /// The fields a window adds to `window.list` and tree window nodes.
    static func window(_ geometry: MainWindowGeometry) -> [String: Any] {
        [
            "name": geometry.name ?? NSNull(),
            "theme": [
                "override": geometry.themeOverride ?? NSNull(),
                "effective": geometry.effectiveTheme,
            ] as [String: Any],
            "window_number": geometry.windowNumber ?? NSNull(),
            "frame": geometry.frame?.c11Payload ?? NSNull(),
            "display": displayRef(geometry.display),
            "frame_on_display": geometry.frameOnDisplay?.c11Payload ?? NSNull(),
            "visible_fraction": geometry.visibleFraction ?? NSNull(),
            "state": [
                "key": geometry.isKey,
                "main": geometry.isMain,
                "minimized": geometry.isMinimized,
                "fullscreen": geometry.isFullScreen,
                "on_active_space": geometry.isOnActiveSpace,
                "visible": geometry.isVisible,
            ],
        ]
    }
}

extension AppDelegate {
    enum WindowAttributeFailure: Error, Equatable {
        case notFound
        case invalidName(WindowNamePolicy.Rejection)
        case unknownTheme(String)
    }

    enum WindowMoveFailure: Error, Equatable {
        case notFound
        case fullscreen
        case minimized
        case noDisplays
        case display(DisplayArrangement.RefError)
        case plan(WindowPlacementPlan.Failure)
    }

    struct WindowMoveResult {
        let requested: CGRect
        let before: MainWindowGeometry
        let after: MainWindowGeometry
        var changed: Bool { before.frame != after.frame }
    }

    // MARK: Displays

    /// Every connected display in top-left global points, numbered left to right.
    static func currentDisplayGeometry() -> [DisplayGeometry] {
        let screens = NSScreen.screens
        guard let mainHeight = screens.first?.frame.maxY else { return [] }
        let displays = screens.compactMap { screen -> DisplayGeometry? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID).map { unmanaged -> String in
                let cfUUID = unmanaged.takeRetainedValue()
                return CFUUIDCreateString(nil, cfUUID) as String
            }
            return DisplayGeometry(
                uuid: uuid,
                displayID: displayID,
                name: screen.localizedName,
                isMain: CGDisplayIsMain(displayID) != 0,
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                frame: DisplayArrangement.topLeft(fromAppKit: screen.frame, mainScreenHeight: mainHeight),
                visibleFrame: DisplayArrangement.topLeft(fromAppKit: screen.visibleFrame, mainScreenHeight: mainHeight),
                scale: screen.backingScaleFactor,
                index: 0
            )
        }
        return DisplayArrangement.ordered(displays)
    }

    // MARK: Window geometry

    func mainWindowGeometry(windowId: UUID, displays: [DisplayGeometry]? = nil) -> MainWindowGeometry? {
        guard let entry = mainWindowEntries().first(where: { $0.windowId == windowId }) else { return nil }
        return makeWindowGeometry(windowId: windowId, window: entry.window,
                                  displays: displays ?? Self.currentDisplayGeometry())
    }

    func allMainWindowGeometry(displays: [DisplayGeometry]? = nil) -> [UUID: MainWindowGeometry] {
        let displays = displays ?? Self.currentDisplayGeometry()
        var result: [UUID: MainWindowGeometry] = [:]
        for entry in mainWindowEntries() {
            result[entry.windowId] = makeWindowGeometry(windowId: entry.windowId, window: entry.window, displays: displays)
        }
        return result
    }

    private func makeWindowGeometry(windowId: UUID, window: NSWindow?, displays: [DisplayGeometry]) -> MainWindowGeometry {
        let store = WindowAttributesStore.shared
        let themes = ThemeManager.shared
        let override = store.themeName(for: windowId)
        let effective = themes.effectiveThemeName(windowThemeName: override)
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = window.map { DisplayArrangement.topLeft(fromAppKit: $0.frame, mainScreenHeight: mainHeight) }
        let display = frame.flatMap { DisplayArrangement.display(for: $0, in: displays) }
        return MainWindowGeometry(
            windowId: windowId,
            windowNumber: window.map(\.windowNumber),
            name: store.name(for: windowId),
            themeOverride: override,
            effectiveTheme: effective,
            frame: frame,
            display: display,
            isKey: window?.isKeyWindow ?? false,
            isMain: window?.isMainWindow ?? false,
            isMinimized: window?.isMiniaturized ?? false,
            isFullScreen: window?.styleMask.contains(.fullScreen) ?? false,
            isOnActiveSpace: window?.isOnActiveSpace ?? false,
            isVisible: window?.isVisible ?? false
        )
    }

    // MARK: Name and theme

    /// Names (or, with nil or blank, unnames) a window. Names are unique.
    func setMainWindowName(windowId: UUID, name: String?) -> Result<String?, WindowAttributeFailure> {
        let entries = mainWindowEntries()
        guard let entry = entries.first(where: { $0.windowId == windowId }) else { return .failure(.notFound) }
        let store = WindowAttributesStore.shared
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let applied: String?
        if trimmed.isEmpty {
            applied = nil
        } else {
            var others: [UUID: String] = [:]
            for other in entries where other.windowId != windowId {
                if let otherName = store.name(for: other.windowId) { others[other.windowId] = otherName }
            }
            switch WindowNamePolicy.validate(trimmed, others: others) {
            case .success(let valid): applied = valid
            case .failure(let error): return .failure(.invalidName(error.rejection))
            }
        }
        store.setName(applied, for: windowId)
        entry.window?.title = applied ?? ""
        saveSessionAfterWindowAttributeChange()
        return .success(applied)
    }

    /// Gives a window its own theme, or (nil or blank) returns it to the app theme.
    func setMainWindowTheme(windowId: UUID, themeName: String?) -> Result<String?, WindowAttributeFailure> {
        guard mainWindowEntries().contains(where: { $0.windowId == windowId }) else { return .failure(.notFound) }
        let trimmed = themeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, ThemeManager.shared.descriptor(named: trimmed) == nil {
            return .failure(.unknownTheme(trimmed))
        }
        let applied = trimmed.isEmpty ? nil : trimmed
        WindowAttributesStore.shared.setThemeName(applied, for: windowId)
        saveSessionAfterWindowAttributeChange()
        return .success(applied)
    }

    /// Restores a window's saved name and theme without validation or a save:
    /// the session they came from already held them. A saved name another open
    /// window now holds is dropped rather than duplicated.
    func restoreMainWindowAttributes(windowId: UUID, name: String?, themeName: String?) {
        let store = WindowAttributesStore.shared
        if let name, !name.isEmpty, !WindowNamePolicy.looksLikeRef(name),
           store.windowId(named: name).map({ $0 == windowId }) ?? true {
            store.setName(name, for: windowId)
        }
        if let themeName, !themeName.isEmpty {
            store.setThemeName(themeName, for: windowId)
        }
    }

    /// The saved UUID for a window being restored, unless it is malformed or
    /// an open window already has it.
    func restorableWindowId(_ saved: String?) -> UUID? {
        guard let saved, let id = UUID(uuidString: saved) else { return nil }
        return mainWindowEntries().contains(where: { $0.windowId == id }) ? nil : id
    }

    /// A short label for a window in menus: its name, else "Window N".
    func menuLabel(forWindowId windowId: UUID, fallbackNumber: Int) -> String {
        if let name = WindowAttributesStore.shared.name(for: windowId) { return name }
        return String(localized: "menu.windowNumber", defaultValue: "Window \(fallbackNumber)")
    }

    // MARK: Placement

    /// Moves a window to a display and/or frame. Never raises, activates or
    /// switches the visible workspace.
    func moveMainWindow(
        windowId: UUID,
        displayRef: String?,
        frame: CGRect?,
        preset: WindowPlacementPlan.Preset?
    ) -> Result<WindowMoveResult, WindowMoveFailure> {
        guard let entry = mainWindowEntries().first(where: { $0.windowId == windowId }),
              let window = entry.window else { return .failure(.notFound) }
        guard !window.styleMask.contains(.fullScreen) else { return .failure(.fullscreen) }
        guard !window.isMiniaturized else { return .failure(.minimized) }
        let displays = Self.currentDisplayGeometry()
        guard !displays.isEmpty, let mainHeight = NSScreen.screens.first?.frame.maxY else {
            return .failure(.noDisplays)
        }
        var target: DisplayGeometry?
        if let displayRef {
            switch DisplayArrangement.resolve(displayRef, in: displays) {
            case .success(let display): target = display
            case .failure(let error): return .failure(.display(error))
            }
        }
        let before = makeWindowGeometry(windowId: windowId, window: window, displays: displays)
        let current = DisplayArrangement.topLeft(fromAppKit: window.frame, mainScreenHeight: mainHeight)
        let planned: CGRect
        switch WindowPlacementPlan.plan(
            current: current,
            currentDisplay: before.display,
            targetDisplay: target,
            frame: frame,
            preset: preset,
            minSize: window.minSize
        ) {
        case .success(let rect): planned = rect
        case .failure(let failure): return .failure(.plan(failure))
        }
        let appKitFrame = DisplayArrangement.appKit(fromTopLeft: planned, mainScreenHeight: mainHeight)
        if appKitFrame != window.frame {
            // Only a frame that changes posts the notifications this flag is for.
            WindowGeometryEventMonitor.shared.noteSocketMove(windowId: windowId)
        }
        window.setFrame(appKitFrame, display: true, animate: false)
        let after = makeWindowGeometry(windowId: windowId, window: window, displays: displays)
        return .success(WindowMoveResult(requested: planned, before: before, after: after))
    }
}

/// Emits `display.changed` and `window.moved` so agents can react to layout
/// changes without polling.
@MainActor
final class WindowGeometryEventMonitor {
    static let shared = WindowGeometryEventMonitor()

    private var observers: [NSObjectProtocol] = []
    private var lastDisplays: [DisplayGeometry] = []
    private var displayWork: DispatchWorkItem?
    private var windowWork: [UUID: DispatchWorkItem] = [:]
    private var lastWindowFrames: [UUID: (frame: CGRect, display: String?)] = [:]
    private var socketMoves: Set<UUID> = []

    static let windowSettleDelay: TimeInterval = 0.4
    static let displaySettleDelay: TimeInterval = 0.3

    func start() {
        guard observers.isEmpty else { return }
        lastDisplays = AppDelegate.currentDisplayGeometry()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDisplayCheck() }
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.windowGeometryDidChange(window) }
            })
        }
    }

    /// The next settle of this window was caused by `window.move`.
    func noteSocketMove(windowId: UUID) {
        socketMoves.insert(windowId)
    }

    /// Forgets a closed window.
    func forget(windowId: UUID) {
        windowWork.removeValue(forKey: windowId)?.cancel()
        lastWindowFrames.removeValue(forKey: windowId)
        socketMoves.remove(windowId)
    }

    private func windowGeometryDidChange(_ window: NSWindow) {
        guard let appDelegate = AppDelegate.shared,
              let windowId = appDelegate.mainWindowId(for: window) else { return }
        windowWork[windowId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.windowDidSettle(windowId) }
        }
        windowWork[windowId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.windowSettleDelay, execute: work)
    }

    private func windowDidSettle(_ windowId: UUID) {
        windowWork.removeValue(forKey: windowId)
        guard let geometry = AppDelegate.shared?.mainWindowGeometry(windowId: windowId),
              let frame = geometry.frame else { return }
        let displayKey = geometry.display?.uuid ?? geometry.display.map { String($0.displayID) }
        let previous = lastWindowFrames[windowId]
        lastWindowFrames[windowId] = (frame, displayKey)
        let source = socketMoves.remove(windowId) != nil ? "socket" : "app"
        guard previous.map({ $0.frame != frame || $0.display != displayKey }) ?? true else { return }
        var payload = WindowGeometryPayload.window(geometry)
        payload["source"] = source
        payload["display_changed"] = previous.map { $0.display != displayKey } ?? false
        payload["previous_display_id"] = previous?.display ?? NSNull()
        EventEmitter.shared.emitWindowMoved(windowId: windowId, payload: payload)
    }

    private func scheduleDisplayCheck() {
        displayWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.displaysDidSettle() }
        }
        displayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displaySettleDelay, execute: work)
    }

    private func displaysDidSettle() {
        displayWork = nil
        let displays = AppDelegate.currentDisplayGeometry()
        guard displays != lastDisplays else { return }
        let key: (DisplayGeometry) -> String = { $0.uuid ?? String($0.displayID) }
        let before = Set(lastDisplays.map(key))
        let after = Set(displays.map(key))
        lastDisplays = displays
        EventEmitter.shared.emitDisplayChanged(
            displays: displays.map(WindowGeometryPayload.display),
            added: after.subtracting(before).sorted(),
            removed: before.subtracting(after).sorted()
        )
    }
}

// MARK: - Window menu

extension AppDelegate {
    /// The main window the Window menu acts on: the key or main window when it
    /// is a terminal window, else the last active one.
    func activeMainWindowIdForMenu() -> UUID? {
        for candidate in [NSApp.keyWindow, NSApp.mainWindow] {
            if let candidate, let id = mainWindowId(for: candidate),
               mainWindowEntries().contains(where: { $0.windowId == id }) {
                return id
            }
        }
        return WindowMenuState.shared.activeWindowId
    }

    /// Window ▸ Rename Window…: a sheet on that window (never a nested modal
    /// loop, which would block socket work).
    func promptRenameActiveMainWindow() {
        guard let windowId = activeMainWindowIdForMenu(),
              let window = mainWindow(for: windowId) else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.renameWindow.title", defaultValue: "Rename Window")
        alert.informativeText = String(
            localized: "dialog.renameWindow.message",
            defaultValue: "The name shows in the title bar and works as a --window ref. Leave it empty to remove it."
        )
        let input = NSTextField(string: WindowAttributesStore.shared.name(for: windowId) ?? "")
        input.placeholderString = String(localized: "dialog.renameWindow.placeholder", defaultValue: "Window name")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            switch self.setMainWindowName(windowId: windowId, name: input.stringValue) {
            case .success, .failure(.notFound):
                return
            case .failure(.invalidName(let rejection)):
                let refusal = NSAlert()
                refusal.messageText = String(localized: "dialog.renameWindow.refused", defaultValue: "That name can't be used")
                refusal.informativeText = Self.localizedWindowNameRejection(rejection)
                refusal.beginSheetModal(for: window)
            case .failure:
                return
            }
        }
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(input)
            input.selectText(nil)
        }
    }

    static func localizedWindowNameRejection(_ rejection: WindowNamePolicy.Rejection) -> String {
        switch rejection {
        case .empty:
            return String(localized: "dialog.renameWindow.refused.empty", defaultValue: "Enter a name.")
        case .tooLong:
            return String(localized: "dialog.renameWindow.refused.tooLong", defaultValue: "Use 64 characters or fewer.")
        case .looksLikeRef:
            return String(
                localized: "dialog.renameWindow.refused.looksLikeRef",
                defaultValue: "A name can't be only a number, a UUID, or a ref like window:2."
            )
        case .inUse:
            return String(localized: "dialog.renameWindow.refused.inUse", defaultValue: "Another window already has that name.")
        }
    }
}

/// Window ▸ Theme: Use App Theme, then every theme, checked for the active window.
struct WindowThemeMenu: View {
    @ObservedObject private var store = WindowAttributesStore.shared
    @ObservedObject private var menuState = WindowMenuState.shared
    @ObservedObject private var themes = ThemeManager.shared

    var body: some View {
        // Reading activeWindowId makes the menu follow the active window.
        let _ = menuState.activeWindowId
        let windowId = AppDelegate.shared?.activeMainWindowIdForMenu()
        let current = windowId.flatMap { store.themeName(for: $0) }
        Menu(String(localized: "menu.window.theme", defaultValue: "Theme")) {
            Toggle(
                String(localized: "menu.window.theme.useApp", defaultValue: "Use App Theme"),
                isOn: Binding(get: { current == nil }, set: { on in
                    guard on, let windowId else { return }
                    _ = AppDelegate.shared?.setMainWindowTheme(windowId: windowId, themeName: nil)
                })
            )
            Divider()
            ForEach(themes.availableThemes.map(\.identity.name), id: \.self) { name in
                Toggle(name, isOn: Binding(get: { current == name }, set: { on in
                    guard on, let windowId else { return }
                    _ = AppDelegate.shared?.setMainWindowTheme(windowId: windowId, themeName: name)
                }))
            }
        }
        .disabled(windowId == nil)
    }
}
