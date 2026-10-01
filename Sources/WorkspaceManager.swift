import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CoreVideo
import Combine
import os


/// Always-on signpost facade for workspace-switch perf instrumentation.
///
/// Wraps `os_signpost` with a single `OSLog` so Instruments.app can graph the
/// switch path (Time Profiler → Points of Interest, or os_signpost lane).
/// Operates in DEBUG and Release builds; user-facing perf regressions are
/// observable from production traces.
///
/// Lifecycle: TabManager opens an interval at `selectedTabId.didSet` and closes
/// it after the queued async side-effects complete. View-layer code emits phase
/// events (`view.selectedChange`, `handoff.start`, `handoff.complete`,
/// `mount.reconcile`, `swiftui.update`, `swiftui.dismantle`) attached to the
/// same `OSSignpostID` so they appear nested under the interval.
enum WorkspaceSwitchSignpost {
    static let log = OSLog(subsystem: "com.stage11.c11", category: "WorkspaceSwitch")

    static func makeID() -> OSSignpostID {
        OSSignpostID(log: log)
    }

    static func begin(_ id: OSSignpostID, _ message: String) {
        os_signpost(.begin, log: log, name: "Switch", signpostID: id, "%{public}s", message)
    }

    static func end(_ id: OSSignpostID, _ message: String) {
        os_signpost(.end, log: log, name: "Switch", signpostID: id, "%{public}s", message)
    }

    static func event(_ id: OSSignpostID, _ name: StaticString, _ message: String) {
        os_signpost(.event, log: log, name: name, signpostID: id, "%{public}s", message)
    }
}

enum NewWorkspacePlacement: String, CaseIterable, Identifiable {
    case top
    case afterCurrent
    case end

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top:
            return String(localized: "workspace.placement.top", defaultValue: "Top")
        case .afterCurrent:
            return String(localized: "workspace.placement.afterCurrent", defaultValue: "After current")
        case .end:
            return String(localized: "workspace.placement.end", defaultValue: "End")
        }
    }

    var description: String {
        switch self {
        case .top:
            return String(
                localized: "workspace.placement.top.description",
                defaultValue: "New workspaces drop in at the top."
            )
        case .afterCurrent:
            return String(
                localized: "workspace.placement.afterCurrent.description",
                defaultValue: "New workspaces drop in right after the active one."
            )
        case .end:
            return String(
                localized: "workspace.placement.end.description",
                defaultValue: "New workspaces drop in at the bottom."
            )
        }
    }
}

enum WorkspaceAutoReorderSettings {
    static let key = "workspaceAutoReorderOnNotification"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum LastTabCloseShortcutSettings {
    static let key = "closeWorkspaceOnLastSurfaceShortcut"
    // Keep the legacy stored meaning so existing values still map to the same
    // behavior. The default is flipped to preserve current Cmd+W behavior.
    static let defaultValue = true

    static func closesWorkspace(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum SidebarBranchLayoutSettings {
    static let key = "sidebarBranchVerticalLayout"
    static let defaultVerticalLayout = true

    static func usesVerticalLayout(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultVerticalLayout
        }
        return defaults.bool(forKey: key)
    }
}

/// "Show surface IDs in tab titles": when on, every surface tab in the bonsplit
/// tab bar (and the surface title bar) renders its `surface:N` ordinal as an
/// "N: " title prefix so a voice operator can address any tab by its number.
enum TabOrdinalDisplaySettings {
    static let showSurfaceIdsInTabTitlesKey = "showSurfaceIdsInTabTitles"
    static let defaultShowSurfaceIds = false

    static func showsSurfaceIds(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showSurfaceIdsInTabTitlesKey) == nil {
            return defaultShowSurfaceIds
        }
        return defaults.bool(forKey: showSurfaceIdsInTabTitlesKey)
    }
}

/// KVO bridge so each `Workspace` (an `ObservableObject`, not an `NSObject`)
/// can react to the "Show surface IDs in tab titles" toggle live, without an
/// app restart. Mirrors `SurfaceAvailabilityObserver`.
final class TabOrdinalDisplayObserver: NSObject {
    private let onChange: () -> Void
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        super.init()
        defaults.addObserver(
            self,
            forKeyPath: TabOrdinalDisplaySettings.showSurfaceIdsInTabTitlesKey,
            options: [.new],
            context: nil
        )
    }

    deinit {
        defaults.removeObserver(
            self,
            forKeyPath: TabOrdinalDisplaySettings.showSurfaceIdsInTabTitlesKey
        )
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == TabOrdinalDisplaySettings.showSurfaceIdsInTabTitlesKey else { return }
        let onChange = self.onChange
        Task { @MainActor in onChange() }
    }
}

enum SidebarWorkspaceDetailSettings {
    static let hideAllDetailsKey = "sidebarHideAllDetails"
    static let showNotificationMessageKey = "sidebarShowNotificationMessage"
    static let defaultHideAllDetails = false
    static let defaultShowNotificationMessage = true

    static func hidesAllDetails(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hideAllDetailsKey) == nil {
            return defaultHideAllDetails
        }
        return defaults.bool(forKey: hideAllDetailsKey)
    }

    static func showsNotificationMessage(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showNotificationMessageKey) == nil {
            return defaultShowNotificationMessage
        }
        return defaults.bool(forKey: showNotificationMessageKey)
    }

    static func resolvedNotificationMessageVisibility(
        showNotificationMessage: Bool,
        hideAllDetails: Bool
    ) -> Bool {
        showNotificationMessage && !hideAllDetails
    }
}

struct SidebarWorkspaceAuxiliaryDetailVisibility: Equatable {
    let showsMetadata: Bool
    let showsLog: Bool
    let showsProgress: Bool
    let showsBranchDirectory: Bool
    let showsPullRequests: Bool
    let showsPorts: Bool

    static let hidden = Self(
        showsMetadata: false,
        showsLog: false,
        showsProgress: false,
        showsBranchDirectory: false,
        showsPullRequests: false,
        showsPorts: false
    )

    static func resolved(
        showMetadata: Bool,
        showLog: Bool,
        showProgress: Bool,
        showBranchDirectory: Bool,
        showPullRequests: Bool,
        showPorts: Bool,
        hideAllDetails: Bool
    ) -> Self {
        guard !hideAllDetails else { return .hidden }
        return Self(
            showsMetadata: showMetadata,
            showsLog: showLog,
            showsProgress: showProgress,
            showsBranchDirectory: showBranchDirectory,
            showsPullRequests: showPullRequests,
            showsPorts: showPorts
        )
    }
}

enum SidebarActiveWorkspaceIndicatorStyle: String, CaseIterable, Identifiable {
    case leftRail
    case solidFill

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftRail:
            return String(localized: "sidebar.activeTabIndicator.leftRail", defaultValue: "Left Rail")
        case .solidFill:
            return String(localized: "sidebar.activeTabIndicator.solidFill", defaultValue: "Solid Fill")
        }
    }
}

enum SidebarActiveWorkspaceIndicatorSettings {
    static let styleKey = "sidebarActiveTabIndicatorStyle"
    static let defaultStyle: SidebarActiveWorkspaceIndicatorStyle = .leftRail

    static func resolvedStyle(rawValue: String?) -> SidebarActiveWorkspaceIndicatorStyle {
        guard let rawValue else { return defaultStyle }
        if let style = SidebarActiveWorkspaceIndicatorStyle(rawValue: rawValue) {
            return style
        }

        // Legacy values from earlier iterations map to the closest modern option.
        switch rawValue {
        case "rail":
            return .leftRail
        case "border", "wash", "lift", "typography", "washRail", "blueWashColorRail":
            return .solidFill
        default:
            return defaultStyle
        }
    }

    static func current(defaults: UserDefaults = .standard) -> SidebarActiveWorkspaceIndicatorStyle {
        resolvedStyle(rawValue: defaults.string(forKey: styleKey))
    }
}

enum WorkspacePlacementSettings {
    static let placementKey = "newWorkspacePlacement"
    static let defaultPlacement: NewWorkspacePlacement = .afterCurrent

    static func current(defaults: UserDefaults = .standard) -> NewWorkspacePlacement {
        guard let raw = defaults.string(forKey: placementKey),
              let placement = NewWorkspacePlacement(rawValue: raw) else {
            return defaultPlacement
        }
        return placement
    }

    static func insertionIndex(
        placement: NewWorkspacePlacement,
        selectedIndex: Int?,
        selectedIsPinned: Bool,
        pinnedCount: Int,
        totalCount: Int
    ) -> Int {
        let clampedTotalCount = max(0, totalCount)
        let clampedPinnedCount = max(0, min(pinnedCount, clampedTotalCount))

        switch placement {
        case .top:
            // Keep pinned workspaces grouped at the top by inserting ahead of unpinned items.
            return clampedPinnedCount
        case .end:
            return clampedTotalCount
        case .afterCurrent:
            guard let selectedIndex, clampedTotalCount > 0 else {
                return clampedTotalCount
            }
            let clampedSelectedIndex = max(0, min(selectedIndex, clampedTotalCount - 1))
            if selectedIsPinned {
                return clampedPinnedCount
            }
            return min(clampedSelectedIndex + 1, clampedTotalCount)
        }
    }
}

struct WorkspaceColorEntry: Equatable, Identifiable {
    let name: String
    let hex: String

    var id: String { "\(name)-\(hex)" }
}

enum WorkspaceColorSettings {
    static let defaultOverridesKey = "workspaceTabColor.defaultOverrides"
    static let customColorsKey = "workspaceTabColor.customColors"
    static let maxCustomColors = 24

    private static let originalPRPalette: [WorkspaceColorEntry] = [
        WorkspaceColorEntry(name: "Red", hex: "#C0392B"),
        WorkspaceColorEntry(name: "Crimson", hex: "#922B21"),
        WorkspaceColorEntry(name: "Orange", hex: "#A04000"),
        WorkspaceColorEntry(name: "Amber", hex: "#7D6608"),
        WorkspaceColorEntry(name: "Olive", hex: "#4A5C18"),
        WorkspaceColorEntry(name: "Green", hex: "#196F3D"),
        WorkspaceColorEntry(name: "Teal", hex: "#006B6B"),
        WorkspaceColorEntry(name: "Aqua", hex: "#0E6B8C"),
        WorkspaceColorEntry(name: "Blue", hex: "#1565C0"),
        WorkspaceColorEntry(name: "Navy", hex: "#1A5276"),
        WorkspaceColorEntry(name: "Indigo", hex: "#283593"),
        WorkspaceColorEntry(name: "Purple", hex: "#6A1B9A"),
        WorkspaceColorEntry(name: "Magenta", hex: "#AD1457"),
        WorkspaceColorEntry(name: "Rose", hex: "#880E4F"),
        WorkspaceColorEntry(name: "Brown", hex: "#7B3F00"),
        WorkspaceColorEntry(name: "Charcoal", hex: "#3E4B5E"),
    ]

    static var defaultPalette: [WorkspaceColorEntry] {
        originalPRPalette
    }

    static func palette(defaults: UserDefaults = .standard) -> [WorkspaceColorEntry] {
        defaultPaletteWithOverrides(defaults: defaults) + customColorEntries(defaults: defaults)
    }

    static func defaultPaletteWithOverrides(defaults: UserDefaults = .standard) -> [WorkspaceColorEntry] {
        let palette = defaultPalette
        let overrides = defaultOverrideMap(defaults: defaults)
        return palette.map { entry in
            WorkspaceColorEntry(name: entry.name, hex: overrides[entry.name] ?? entry.hex)
        }
    }

    static func defaultColorHex(named name: String, defaults: UserDefaults = .standard) -> String {
        let palette = defaultPalette
        guard let entry = palette.first(where: { $0.name == name }) else {
            return palette.first?.hex ?? "#1565C0"
        }
        return defaultOverrideMap(defaults: defaults)[name] ?? entry.hex
    }

    static func setDefaultColor(named name: String, hex: String, defaults: UserDefaults = .standard) {
        let palette = defaultPalette
        guard let entry = palette.first(where: { $0.name == name }),
              let normalized = normalizedHex(hex) else { return }

        var overrides = defaultOverrideMap(defaults: defaults)
        if normalized == entry.hex {
            overrides.removeValue(forKey: name)
        } else {
            overrides[name] = normalized
        }
        saveDefaultOverrideMap(overrides, defaults: defaults)
    }

    static func customColors(defaults: UserDefaults = .standard) -> [String] {
        guard let raw = defaults.array(forKey: customColorsKey) as? [String] else { return [] }
        var result: [String] = []
        var seen: Set<String> = []
        for value in raw {
            guard let normalized = normalizedHex(value), seen.insert(normalized).inserted else { continue }
            result.append(normalized)
            if result.count >= maxCustomColors { break }
        }
        return result
    }

    static func customColorEntries(defaults: UserDefaults = .standard) -> [WorkspaceColorEntry] {
        customColors(defaults: defaults).enumerated().map { index, hex in
            WorkspaceColorEntry(name: "Custom \(index + 1)", hex: hex)
        }
    }

    @discardableResult
    static func addCustomColor(_ hex: String, defaults: UserDefaults = .standard) -> String? {
        guard let normalized = normalizedHex(hex) else { return nil }
        var colors = customColors(defaults: defaults)
        colors.removeAll { $0 == normalized }
        colors.insert(normalized, at: 0)
        setCustomColors(colors, defaults: defaults)
        return normalized
    }

    static func removeCustomColor(_ hex: String, defaults: UserDefaults = .standard) {
        guard let normalized = normalizedHex(hex) else { return }
        var colors = customColors(defaults: defaults)
        colors.removeAll { $0 == normalized }
        setCustomColors(colors, defaults: defaults)
    }

    static func setCustomColors(_ hexes: [String], defaults: UserDefaults = .standard) {
        var normalizedColors: [String] = []
        var seen: Set<String> = []
        for value in hexes {
            guard let normalized = normalizedHex(value), seen.insert(normalized).inserted else { continue }
            normalizedColors.append(normalized)
            if normalizedColors.count >= maxCustomColors { break }
        }

        if normalizedColors.isEmpty {
            defaults.removeObject(forKey: customColorsKey)
        } else {
            defaults.set(normalizedColors, forKey: customColorsKey)
        }
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultOverridesKey)
        defaults.removeObject(forKey: customColorsKey)
    }

    static func normalizedHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6 else { return nil }
        guard UInt64(body, radix: 16) != nil else { return nil }
        return "#" + body.uppercased()
    }

    static func displayColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> Color? {
        guard let color = displayNSColor(hex: hex, colorScheme: colorScheme, forceBright: forceBright) else {
            return nil
        }
        return Color(nsColor: color)
    }

    static func displayNSColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> NSColor? {
        guard let normalized = normalizedHex(hex),
              let baseColor = NSColor(hex: normalized) else {
            return nil
        }

        if forceBright || colorScheme == .dark {
            return brightenedForDarkAppearance(baseColor)
        }
        return baseColor
    }

    private static func defaultOverrideMap(defaults: UserDefaults) -> [String: String] {
        guard let raw = defaults.dictionary(forKey: defaultOverridesKey) as? [String: String] else { return [:] }
        let validNames = Set(defaultPalette.map(\.name))
        var normalized: [String: String] = [:]
        for (name, hex) in raw {
            guard validNames.contains(name),
                  let normalizedHex = normalizedHex(hex) else { continue }
            normalized[name] = normalizedHex
        }
        return normalized
    }

    private static func saveDefaultOverrideMap(_ map: [String: String], defaults: UserDefaults) {
        if map.isEmpty {
            defaults.removeObject(forKey: defaultOverridesKey)
        } else {
            defaults.set(map, forKey: defaultOverridesKey)
        }
    }

    private static func brightenedForDarkAppearance(_ color: NSColor) -> NSColor {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let boostedBrightness = min(1, max(brightness, 0.62) + ((1 - brightness) * 0.28))
        // Preserve neutral grays when brightening to avoid introducing hue shifts.
        let boostedSaturation: CGFloat
        if saturation <= 0.08 {
            boostedSaturation = saturation
        } else {
            boostedSaturation = min(1, saturation + ((1 - saturation) * 0.12))
        }

        return NSColor(
            hue: hue,
            saturation: boostedSaturation,
            brightness: boostedBrightness,
            alpha: alpha
        )
    }
}

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
final class NotificationBurstCoalescer {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?

    init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

    func signal(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        pendingAction = action
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        isFlushScheduled = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}

struct RecentlyClosedBrowserStack {
    private(set) var entries: [ClosedBrowserTabRestoreSnapshot] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    mutating func push(_ snapshot: ClosedBrowserTabRestoreSnapshot) {
        entries.append(snapshot)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    mutating func pop() -> ClosedBrowserTabRestoreSnapshot? {
        entries.popLast()
    }
}

#if DEBUG
// Sample the actual IOSurface-backed terminal layer at vsync cadence so UI tests can reliably
// catch a single compositor-frame blank flash and any transient compositor scaling (stretched text).
//
// This is DEBUG-only and used only for UI tests; no polling or display-link loops exist in normal app runtime.
fileprivate final class VsyncIOSurfaceTimelineState {
    struct Target {
        let label: String
        let sample: @MainActor () -> GhosttySurfaceScrollView.DebugFrameSample?
    }

    let frameCount: Int
    let closeFrame: Int
    let lock = NSLock()

    var framesWritten = 0
    var inFlight = false
    var finished = false

    var scheduledActions: [(frame: Int, action: () -> Void)] = []
    var nextActionIndex: Int = 0

    var targets: [Target] = []

    // Results
    var firstBlank: (label: String, frame: Int)?
    var firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?
    var trace: [String] = []

    var link: CVDisplayLink?
    var continuation: CheckedContinuation<Void, Never>?

    init(frameCount: Int, closeFrame: Int) {
        self.frameCount = frameCount
        self.closeFrame = closeFrame
    }

    func tryBeginCapture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        if inFlight { return false }
        inFlight = true
        return true
    }

    func endCapture() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

fileprivate func cmuxVsyncIOSurfaceTimelineCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ ctx: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let ctx else { return kCVReturnSuccess }
    let st = Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).takeUnretainedValue()
    if !st.tryBeginCapture() { return kCVReturnSuccess }

    // Sample on the main thread synchronously so we don't "miss" a single compositor frame.
    // (The previous Task/@MainActor hop could be delayed long enough to skip the blank frame.)
    DispatchQueue.main.sync {
        defer { st.endCapture() }
        guard st.framesWritten < st.frameCount else { return }

        while st.nextActionIndex < st.scheduledActions.count {
            let next = st.scheduledActions[st.nextActionIndex]
            if next.frame != st.framesWritten { break }
            st.nextActionIndex += 1
            next.action()
        }

        for t in st.targets {
            guard let s = t.sample() else { continue }

            let iosW = s.iosurfaceWidthPx
            let iosH = s.iosurfaceHeightPx
            let expW = s.expectedWidthPx
            let expH = s.expectedHeightPx
            let gravity = s.layerContentsGravity
            let hasDimensions = iosW > 0 && iosH > 0 && expW > 0 && expH > 0
            let dw = hasDimensions ? abs(iosW - expW) : 0
            let dh = hasDimensions ? abs(iosH - expH) : 0
            let hasSizeMismatch = hasDimensions && (dw > 2 || dh > 2)
            let stretchRisk = (gravity == CALayerContentsGravity.resize.rawValue)

            // Ignore setup/warmup frames before the close action. We only care about
            // regressions that happen at/after the close mutation.
            if st.firstBlank == nil, st.framesWritten >= st.closeFrame, s.isProbablyBlank {
                st.firstBlank = (label: t.label, frame: st.framesWritten)
            }

            if st.firstSizeMismatch == nil,
               st.framesWritten >= st.closeFrame,
               stretchRisk,
               hasSizeMismatch {
                st.firstSizeMismatch = (
                    label: t.label,
                    frame: st.framesWritten,
                    ios: "\(iosW)x\(iosH)",
                    expected: "\(expW)x\(expH)"
                )
            }

            if st.trace.count < 200 {
                st.trace.append("\(st.framesWritten):\(t.label):blank=\(s.isProbablyBlank ? 1 : 0):ios=\(iosW)x\(iosH):exp=\(expW)x\(expH):gravity=\(gravity):key=\(s.layerContentsKey)")
            }
        }

        st.framesWritten += 1
    }

    // Stop/resume outside the main-thread sync block to avoid reentrancy issues.
    if st.framesWritten >= st.frameCount, let link = st.link {
        CVDisplayLinkStop(link)
        st.finish()
        Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
    }

    return kCVReturnSuccess
}
#endif

@MainActor
class WorkspaceManager: ObservableObject {
    private enum WorkspacePullRequestSnapshot: Equatable {
        case unsupportedRepository
        case notFound
        case resolved(SidebarPullRequestState)
        case transientFailure
    }

    private struct InitialWorkspaceGitMetadataSnapshot: Equatable {
        let branch: String?
        let isDirty: Bool
        let pullRequest: WorkspacePullRequestSnapshot
        /// C11-104 — resolved worktree + branch context for the sidebar
        /// chips, computed on the same off-main probe pass so we do not
        /// fork additional git invocations on the hot path.
        let gitContext: ResolvedGitContext?
    }

    private struct CommandResult {
        let stdout: String?
        let stderr: String?
        let exitStatus: Int32?
        let timedOut: Bool
        let executionError: String?
    }

    private static func defaultWorkspaceTitle(number: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "workspace.defaultTitle", defaultValue: "Workspace %lld"),
            Int64(number)
        )
    }

    private struct WorkspaceGitProbeKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private struct GitHubPullRequestViewItem: Decodable {
        let number: Int
        let state: String
        let url: String
    }

    private struct GitHubPullRequestCheckItem: Decodable {
        let bucket: String?
        let state: String?
    }

    /// The window that owns this TabManager. Set by AppDelegate.registerMainWindow().
    /// Used to apply title updates to the correct window instead of NSApp.keyWindow.
    weak var window: NSWindow?

    @Published var workspaces: [Workspace] = []
    @Published private(set) var isWorkspaceCycleHot: Bool = false
    @Published private(set) var pendingBackgroundWorkspaceLoadIds: Set<UUID> = []
    @Published private(set) var debugPinnedWorkspaceLoadIds: Set<UUID> = []

    /// True when the currently selected workspace has a pane interaction presented.
    /// Used by AppDelegate's shortcut dispatcher / modal-window gate (plan §4.8) to
    /// suppress key-equivalent handling while a pane-anchored dialog is on screen.
    ///
    /// Scoped to the selected workspace (not all tabs) so a dialog on a background
    /// workspace doesn't silently make global shortcuts inert — matches
    /// `acceptActivePaneInteractionInKeyWorkspace`'s scope. Annotated @MainActor
    /// because it reads a @MainActor-isolated runtime (synthesis-critical §2.3,
    /// synthesis-standard §1.4).
    @MainActor
    var hasActivePaneInteraction: Bool {
        guard let selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceId }) else {
            return false
        }
        return workspace.paneInteractionRuntime.hasAnyActive
    }

    /// True when the selected workspace has an active workspace-close
    /// confirmation overlay. Distinct from `hasActivePaneInteraction` so
    /// AppDelegate can route Cmd+D / Esc / Return through the workspace
    /// runtime, and so app-level shortcuts stay suppressed while the
    /// destructive close prompt is visible.
    @MainActor
    var hasActiveWorkspaceCloseInteraction: Bool {
        guard let selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceId }) else {
            return false
        }
        return workspace.workspaceCloseInteractionRuntime.hasActive
    }

    /// Cancel the active workspace-close interaction in the selected
    /// workspace. Used as an Esc fallback when the overlay host did not
    /// receive keyDown directly (WKWebView responder edge cases).
    @MainActor
    @discardableResult
    func cancelActiveWorkspaceCloseInteractionInKeyWorkspace() -> Bool {
        guard let selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceId }) else {
            return false
        }
        let runtime = workspace.workspaceCloseInteractionRuntime
        guard let active = runtime.active else { return false }
        runtime.cancel(ifInteractionId: active.id)
        return true
    }

    /// Accept the topmost pane interaction in the currently selected workspace,
    /// preferring the focused panel when it has an active interaction. Used by the
    /// Cmd+D dispatcher (plan §4.8). Returns true when an interaction resolved —
    /// caller should also return true from its key-equivalent handler.
    @MainActor
    @discardableResult
    func acceptActivePaneInteractionInKeyWorkspace(includingDestructiveConfirms: Bool) -> Bool {
        guard let selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceId }) else {
            return false
        }
        let runtime = workspace.paneInteractionRuntime
        // Prefer the focused panel — Cmd+D naturally targets "the dialog the user is
        // looking at," which is the one anchored on the currently focused panel.
        // Otherwise take any active interaction — there's only ever one per panel,
        // and multiple-panel-with-active-interaction is rare.
        let targetPanelId: UUID? = {
            if let focusedPanelId = workspace.focusedPanelId,
               runtime.hasActive(panelId: focusedPanelId) {
                return focusedPanelId
            }
            return runtime.activePanelIds.first
        }()
        guard let targetPanelId else { return false }
        if !includingDestructiveConfirms, runtime.hasActiveDestructiveConfirm(panelId: targetPanelId) { return false }
        return runtime.acceptActive(panelId: targetPanelId)
    }

    @MainActor
    @discardableResult
    func handleActivePaneInteractionKeyEventInKeyWorkspace(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty || flags == [.shift] else { return false }
        guard let selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceId }) else {
            return false
        }
        let runtime = workspace.paneInteractionRuntime
        if let focusedPanelId = workspace.focusedPanelId,
           runtime.hasActive(panelId: focusedPanelId),
           runtime.handleKeyDown(
               panelId: focusedPanelId,
               keyCode: Int(event.keyCode),
               shift: flags.contains(.shift)
           ) {
            return true
        }
        for panelId in runtime.activePanelIds where runtime.handleKeyDown(
            panelId: panelId,
            keyCode: Int(event.keyCode),
            shift: flags.contains(.shift)
        ) {
            return true
        }
        return false
    }

    /// Global monotonically increasing counter for CMUX_PORT ordinal assignment.
    /// Static so port ranges don't overlap across multiple windows (each window has its own TabManager).
    private static var nextPortOrdinal: Int = 0
    private static let initialWorkspaceGitProbeDelays: [TimeInterval] = [0, 0.5, 1.5, 3.0, 6.0, 10.0]
    private nonisolated static let workspacePullRequestProbeTimeout: TimeInterval = 5.0
    @Published var selectedWorkspaceId: UUID? {
        willSet {
#if DEBUG
            guard newValue != selectedWorkspaceId else {
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
                debugPreparedWorkspaceSwitchTarget = nil
                return
            }

            if debugPreparedWorkspaceSwitchTarget == newValue {
                debugPreparedWorkspaceSwitchTarget = nil
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
            } else {
                let trigger = (debugPendingWorkspaceSwitchTarget == newValue
                    ? debugPendingWorkspaceSwitchTrigger
                    : nil) ?? "direct"
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
                debugBeginWorkspaceSwitch(
                    trigger: trigger,
                    from: selectedWorkspaceId,
                    to: newValue
                )
            }
#endif
        }
        didSet {
            guard selectedWorkspaceId != oldValue else { return }
            // C11-243: workspace switch changes what the operator is looking at.
            TabSeenTracker.shared.refresh()
            TabRailTipCenter.shared.scheduleRefresh()
            // C11-163: workspace selected → events stream. Fires on every
            // selection route (socket, keyboard, click, close-fallback) since
            // they all land here.
            if let selected = selectedWorkspaceId {
                EventEmitter.shared.emitWorkspaceSelected(previous: oldValue, selected: selected)
            }
            sentryBreadcrumb("workspace.switch", data: surfaceShapeSummary(tabCount: workspaces.count))

            // Phase 0 instrumentation: open a signpost interval spanning the
            // entire switch (didSet → queued async block) so Instruments.app
            // can graph it. Always-on, DEBUG and Release.
            let switchSignpostID = WorkspaceSwitchSignpost.makeID()
            self.currentSwitchSignpostID = switchSignpostID
            let switchStartTime = CACurrentMediaTime()
            self.currentSwitchStartTime = switchStartTime
            WorkspaceSwitchSignpost.begin(
                switchSignpostID,
                "from=\(String(oldValue?.uuidString.prefix(5) ?? "nil")) " +
                "to=\(String(selectedWorkspaceId?.uuidString.prefix(5) ?? "nil")) " +
                "tabs=\(workspaces.count)"
            )

            let previousWorkspaceId = oldValue
            if let previousWorkspaceId,
               let previousPanelId = focusedPanelId(for: previousWorkspaceId) {
                lastFocusedTabByWorkspace[previousWorkspaceId] = previousPanelId
            }
            if !isNavigatingHistory, let selectedWorkspaceId {
                recordWorkspaceInHistory(selectedWorkspaceId)
            }
            // C11-228: throttle/activate from the model, synchronously, so the
            // edge can't be lost in the hidden SwiftUI subtree or superseded by
            // a newer switch's async block.
            if let previousWorkspaceId, let previous = workspaces.first(where: { $0.id == previousWorkspaceId }) {
                previous.applyPanelVisibility(workspaceVisible: false)
            }
            if let selectedWorkspaceId, let selected = workspaces.first(where: { $0.id == selectedWorkspaceId }) {
                selected.applyPanelVisibility(workspaceVisible: true)
            }
#if DEBUG
            let switchId = debugWorkspaceSwitchId
            let switchDtMs = debugWorkspaceSwitchStartTime > 0
                ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
                : 0
            dlog(
                "ws.select.didSet id=\(switchId) from=\(Self.debugShortWorkspaceId(previousWorkspaceId)) " +
                "to=\(Self.debugShortWorkspaceId(selectedWorkspaceId)) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
            selectionSideEffectsGeneration &+= 1
            let generation = selectionSideEffectsGeneration
            DispatchQueue.main.async { [weak self, switchSignpostID, switchStartTime] in
                guard let self, self.selectionSideEffectsGeneration == generation else {
                    // Block was superseded by a newer switch. Close the signpost
                    // so Instruments doesn't render an unbounded interval.
                    WorkspaceSwitchSignpost.end(switchSignpostID, "superseded")
                    return
                }
#if DEBUG
                let asyncBlockStart = CACurrentMediaTime()
                let switchDtAtAsyncEnter = self.debugWorkspaceSwitchStartTime > 0
                    ? (asyncBlockStart - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                dlog(
                    "ws.select.asyncEnter id=\(self.debugWorkspaceSwitchId) " +
                    "dt=\(Self.debugMsText(switchDtAtAsyncEnter))"
                )
#endif
                self.focusSelectedTabPanel(previousWorkspaceId: previousWorkspaceId)
#if DEBUG
                let postFocusDt = (CACurrentMediaTime() - asyncBlockStart) * 1000
                dlog(
                    "ws.select.asyncPostFocusPanel id=\(self.debugWorkspaceSwitchId) " +
                    "phaseDt=\(Self.debugMsText(postFocusDt))"
                )
#endif
                self.updateWindowTitleForSelectedTab()
#if DEBUG
                let postTitleDt = (CACurrentMediaTime() - asyncBlockStart) * 1000
                dlog(
                    "ws.select.asyncPostTitleUpdate id=\(self.debugWorkspaceSwitchId) " +
                    "phaseDt=\(Self.debugMsText(postTitleDt))"
                )
#endif
                if let selectedWorkspaceId = self.selectedWorkspaceId {
                    self.markFocusedPanelReadIfActive(workspaceId: selectedWorkspaceId)
                }
#if DEBUG
                let postMarkReadDt = (CACurrentMediaTime() - asyncBlockStart) * 1000
                dlog(
                    "ws.select.asyncPostMarkRead id=\(self.debugWorkspaceSwitchId) " +
                    "phaseDt=\(Self.debugMsText(postMarkReadDt))"
                )
#endif

                // Phase 0: close the signpost interval and post a release-safe
                // Sentry breadcrumb with the duration so production traces
                // capture user-facing slowness.
                let dtMs = (CACurrentMediaTime() - switchStartTime) * 1000
                let dtMsRounded = Int(dtMs.rounded())
                WorkspaceSwitchSignpost.end(switchSignpostID, "dt=\(dtMsRounded)ms")
                sentryBreadcrumb("workspace.switch.complete", category: "perf", data: [
                    "dt_ms": dtMsRounded,
                    "tabs": self.workspaces.count
                ])
                if self.currentSwitchSignpostID == switchSignpostID {
                    self.currentSwitchSignpostID = nil
                }

#if DEBUG
                let debugDtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                dlog(
                    "ws.select.asyncDone id=\(self.debugWorkspaceSwitchId) dt=\(Self.debugMsText(debugDtMs)) " +
                    "selected=\(Self.debugShortWorkspaceId(self.selectedWorkspaceId))"
                )
#endif
            }
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var suppressFocusFlash = false
    private var lastFocusedTabByWorkspace: [UUID: UUID] = [:]
    private struct TabTitleUpdateKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }
    private var pendingTabTitleUpdates: [TabTitleUpdateKey: String] = [:]
    private let panelTitleUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    private var recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: 20)
    private let initialWorkspaceGitProbeQueue = DispatchQueue(
        label: "com.stage11.c11.initial-workspace-git-probe",
        qos: .utility
    )
    private var workspaceGitProbeGenerationByKey: [WorkspaceGitProbeKey: UUID] = [:]
    private var workspaceGitProbeTimersByKey: [WorkspaceGitProbeKey: [DispatchSourceTimer]] = [:]

    /// (C11-106) Process-wide cache for `GitContextResolver` results,
    /// shared across all workspaces and surfaces. Reads/writes are
    /// internally locked (`@unchecked Sendable` with an NSLock), so
    /// it is safe to share across the `initialWorkspaceGitProbeQueue`
    /// and any future ad-hoc derivation queues. Lifecycle is tied
    /// to the TabManager singleton; on workspace deletion the cache
    /// entries naturally expire via LRU eviction since no further
    /// resolve will refresh them.
    nonisolated(unsafe) static let gitContextResolverCache = GitContextResolverCache(capacity: 256)

    // Recent tab history for back/forward navigation (like browser history)
    private var workspaceHistory: [UUID] = []
    private var historyIndex: Int = -1
    private var isNavigatingHistory = false
    private let maxHistorySize = 50
    private var selectionSideEffectsGeneration: UInt64 = 0
    private var workspaceCycleGeneration: UInt64 = 0
    private var workspaceCycleCooldownTask: Task<Void, Never>?
    private var pendingWorkspaceUnfocusTarget: (workspaceId: UUID, panelId: UUID)?
    private var sidebarSelectedWorkspaceIds: Set<UUID> = []
    var confirmCloseHandler: ((String, String, Bool) -> Bool)?
    /// Test seam for the workspace-scoped close-confirmation overlay (C11-30).
    /// When set, replaces the async overlay flow with a synchronous callback so
    /// unit tests can drive `closeWorkspaceIfRunningProcess` /
    /// `closeWorkspacesWithConfirmation` without a running AppKit window.
    /// Production callers route through `Workspace.presentConfirmCloseWorkspace`.
    var workspaceCloseConfirmationHandler: ((_ title: String, _ message: String) -> Bool)?
    private struct WorkspaceCreationSnapshot {
        let workspaces: [Workspace]
        let selectedWorkspaceId: UUID?

        var selectedWorkspace: Workspace? {
            guard let selectedWorkspaceId else { return nil }
            return workspaces.first(where: { $0.id == selectedWorkspaceId })
        }
    }
    private var agentPIDSweepTimer: DispatchSourceTimer?

    // Phase 0 instrumentation: always-on (DEBUG and Release) so Instruments.app
    // and Sentry can both observe workspace-switch latency. The DEBUG-only
    // counters above remain because the dlog timeline depends on them.
    /// Signpost ID for the currently in-flight workspace switch, or nil. Set in
    /// `selectedTabId.didSet` and cleared after the queued async block completes.
    /// Read by ContentView and GhosttyTerminalView to attach phase events.
    private(set) var currentSwitchSignpostID: OSSignpostID?
    private var currentSwitchStartTime: CFTimeInterval = 0

#if DEBUG
    private var debugWorkspaceSwitchCounter: UInt64 = 0
    private var debugWorkspaceSwitchId: UInt64 = 0
    private var debugWorkspaceSwitchStartTime: CFTimeInterval = 0
    private var debugPendingWorkspaceSwitchTrigger: String?
    private var debugPendingWorkspaceSwitchTarget: UUID?
    private var debugPreparedWorkspaceSwitchTarget: UUID?
#endif

#if DEBUG
    private var didSetupSplitCloseRightUITest = false
    private var didSetupUITestFocusShortcuts = false
    private var didSetupChildExitSplitUITest = false
    private var didSetupChildExitKeyboardUITest = false
    private var uiTestCancellables = Set<AnyCancellable>()
#endif

    init(initialWorkingDirectory: String? = nil) {
        addWorkspace(workingDirectory: initialWorkingDirectory)
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let workspaceId = notification.userInfo?[GhosttyNotificationKey.workspaceId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                guard let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else { return }
                enqueueTabTitleUpdate(workspaceId: workspaceId, panelId: surfaceId, title: title)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let workspaceId = notification.userInfo?[GhosttyNotificationKey.workspaceId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                markTabReadOnFocusIfActive(workspaceId: workspaceId, panelId: surfaceId)
            }
        })

        startAgentPIDSweepTimer()

#if DEBUG
        setupUITestFocusShortcutsIfNeeded()
        setupSplitCloseRightUITestIfNeeded()
        setupChildExitSplitUITestIfNeeded()
        setupChildExitKeyboardUITestIfNeeded()
#endif
    }

    deinit {
        workspaceCycleCooldownTask?.cancel()
        agentPIDSweepTimer?.cancel()
    }

    // MARK: - Agent PID Sweep

    /// Periodically checks agent PIDs associated with status entries.
    /// If a process has exited (SIGKILL, crash, etc.), clears the stale status entry.
    /// This is the safety net for cases where no hook fires (e.g. SIGKILL).
    private func startAgentPIDSweepTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sweepStaleAgentPIDs()
            }
        }
        timer.resume()
        agentPIDSweepTimer = timer
    }

    private func sweepStaleAgentPIDs() {
        for workspace in workspaces {
            var keysToRemove: [String] = []
            for (key, pid) in workspace.agentPIDs {
                guard pid > 0 else {
                    keysToRemove.append(key)
                    continue
                }
                // kill(pid, 0) probes process liveness without sending a signal.
                // ESRCH = process doesn't exist (stale). EPERM = process exists
                // but we lack permission (not stale, keep tracking).
                errno = 0
                if kill(pid, 0) == -1, POSIXErrorCode(rawValue: errno) == .ESRCH {
                    keysToRemove.append(key)
                }
            }
            if !keysToRemove.isEmpty {
                for key in keysToRemove {
                    workspace.statusEntries.removeValue(forKey: key)
                    workspace.agentPIDs.removeValue(forKey: key)
                }
                // Also clear stale notifications (e.g. "Doing well, thanks!")
                // left behind when Claude was killed without SessionEnd firing.
                AppDelegate.shared?.notificationStore?.clearNotifications(forWorkspaceId: workspace.id)
            }
        }
    }

    private func gitProbeDirectory(for workspace: Workspace, panelId: UUID) -> String? {
        let rawDirectory = workspace.tabDirectories[panelId]
            ?? (workspace.focusedPanelId == panelId ? workspace.currentDirectory : nil)
        return rawDirectory.flatMap(normalizedWorkingDirectory)
    }

    private func scheduleWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String,
        delays: [TimeInterval] = [0]
    ) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }),
              workspace.panels[panelId] != nil,
              let directory = gitProbeDirectory(for: workspace, panelId: panelId) else {
            return
        }

        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: delays,
            reason: reason
        )
    }

    private func wireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserTab = { [weak self] snapshot in
            self?.recentlyClosedBrowsers.push(snapshot)
        }
    }

    private func unwireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserTab = nil
    }

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceId else { return nil }
        return workspaces.first(where: { $0.id == selectedWorkspaceId })
    }

    // Keep selectedTab as convenience alias

    // MARK: - Surface/Panel Compatibility Layer

    /// Returns the focused terminal surface for the selected workspace
    var selectedSurface: TerminalSurface? {
        selectedWorkspace?.focusedTerminalTab?.surface
    }

    /// Returns the focused panel's terminal panel (if it is a terminal)
    var selectedTerminalTab: TerminalTab? {
        selectedWorkspace?.focusedTerminalTab
    }

    var isFindVisible: Bool {
        selectedTerminalTab?.searchState != nil || focusedBrowserTab?.searchState != nil
    }

    var canUseSelectionForFind: Bool {
        selectedTerminalTab?.hasSelection() == true
    }

    func startSearch() {
        if let panel = selectedTerminalTab {
            if panel.searchState == nil {
                panel.searchState = TerminalSurface.SearchState()
            }
            NSLog("Find: startSearch workspace=%@ panel=%@", panel.workspaceId.uuidString, panel.id.uuidString)
            NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
            _ = panel.performBindingAction("start_search")
            return
        }
        if let panel = selectedTerminalTab {
            let hadExistingSearch = panel.searchState != nil
            let handled = startOrFocusTerminalSearch(panel.surface)
            NSLog("Find: startSearch workspace=%@ panel=%@", panel.workspaceId.uuidString, panel.id.uuidString)
#if DEBUG
            dlog(
                "find.startSearch workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
                "panel=\(panel.id.uuidString.prefix(5)) existing=\(hadExistingSearch ? "yes" : "no") " +
                "handled=\(handled ? 1 : 0) " +
                "firstResponder=\(String(describing: panel.surface.uiWindow?.firstResponder))"
            )
#endif
            return
        }

        focusedBrowserTab?.startFind()
    }

    func searchSelection() {
        guard let panel = selectedTerminalTab else { return }
        if panel.searchState == nil {
            panel.searchState = TerminalSurface.SearchState()
        }
        NSLog("Find: searchSelection workspace=%@ panel=%@", panel.workspaceId.uuidString, panel.id.uuidString)
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
        _ = panel.performBindingAction("search_selection")
    }

    func findNext() {
        if let panel = selectedTerminalTab {
            _ = panel.performBindingAction("search:next")
            return
        }

        focusedBrowserTab?.findNext()
    }

    func findPrevious() {
        if let panel = selectedTerminalTab {
            _ = panel.performBindingAction("search:previous")
            return
        }

        focusedBrowserTab?.findPrevious()
    }

    @discardableResult
    func toggleFocusedTerminalCopyMode() -> Bool {
        guard let panel = selectedTerminalTab else { return false }
        return panel.surface.toggleKeyboardCopyMode()
    }

    func hideFind() {
        if let panel = selectedTerminalTab {
            panel.searchState = nil
            return
        }

        focusedBrowserTab?.hideFind()
    }

    @discardableResult
    func addWorkspace(
        workingDirectory overrideWorkingDirectory: String? = nil,
        rootDirectory overrideRootDirectory: String? = nil,
        establishRootFromWorkingDirectory: Bool = true,
        initialTerminalCommand: String? = nil,
        initialTerminalEnvironment: [String: String] = [:],
        select: Bool = true,
        eagerLoadTerminal: Bool = false,
        placementOverride: NewWorkspacePlacement? = nil,
        autoWelcomeIfNeeded: Bool = true
    ) -> Workspace {
        // Snapshot current published state once so workspace creation doesn't repeatedly
        // bounce through Combine-backed accessors while we're preparing the new workspace.
        let snapshot = workspaceCreationSnapshot()
        let nextTabCount = snapshot.workspaces.count + 1
        let defaultTitle = Self.defaultWorkspaceTitle(number: nextTabCount)
        sentryBreadcrumb("workspace.create", data: surfaceShapeSummary(tabCount: nextTabCount))
        let explicitWorkingDirectory = normalizedWorkingDirectory(overrideWorkingDirectory)
        let explicitRootDirectory = normalizedWorkingDirectory(overrideRootDirectory)
        // An explicit root places the first surface too (C11-238): the root
        // governs every new surface in the workspace, including its first.
        let workingDirectory = explicitWorkingDirectory
            ?? explicitRootDirectory
            ?? preferredWorkingDirectoryForNewTab(snapshot: snapshot)
        let rootDirectory = explicitRootDirectory
            ?? (establishRootFromWorkingDirectory ? explicitWorkingDirectory : nil)
        let inheritedConfig = inheritedTerminalConfigForNewWorkspace(snapshot: snapshot)
        let ordinal = Self.nextPortOrdinal
        Self.nextPortOrdinal += 1
        let newWorkspace = Workspace(
            title: defaultTitle,
            stableDefaultTitle: defaultTitle,
            workingDirectory: workingDirectory,
            rootDirectory: rootDirectory,
            portOrdinal: ordinal,
            configTemplate: inheritedConfig,
            initialTerminalCommand: initialTerminalCommand,
            initialTerminalEnvironment: initialTerminalEnvironment
        )
        newWorkspace.owningWorkspaceManager = self
        wireClosedBrowserTracking(for: newWorkspace)
        newWorkspace.startMailboxDispatcher()
        let insertIndex = newTabInsertIndex(snapshot: snapshot, placementOverride: placementOverride)
        if eagerLoadTerminal && !select {
            requestBackgroundWorkspaceLoad(for: newWorkspace.id)
        }
        var updatedTabs = snapshot.workspaces
        if insertIndex >= 0 && insertIndex <= updatedTabs.count {
            updatedTabs.insert(newWorkspace, at: insertIndex)
        } else {
            updatedTabs.append(newWorkspace)
        }
        workspaces = updatedTabs
        if let explicitWorkingDirectory,
           let terminalTab = newWorkspace.focusedTerminalTab {
            scheduleInitialWorkspaceGitMetadataRefresh(
                workspaceId: newWorkspace.id,
                panelId: terminalTab.id,
                directory: explicitWorkingDirectory
            )
        }
        if eagerLoadTerminal {
            if select {
                newWorkspace.focusedTerminalTab?.surface.requestBackgroundSurfaceStartIfNeeded()
            }
        }
        if select {
#if DEBUG
            debugPrimeWorkspaceSwitchTrigger("create", to: newWorkspace.id)
#endif
            selectedWorkspaceId = newWorkspace.id
            NotificationCenter.default.post(
                name: .ghosttyDidFocusTab,
                object: nil,
                userInfo: [GhosttyNotificationKey.workspaceId: newWorkspace.id]
            )
        }
#if DEBUG
        UITestRecorder.incrementInt("addTabInvocations")
        UITestRecorder.record([
            "tabCount": String(updatedTabs.count),
            "selectedTabId": select ? newWorkspace.id.uuidString : (snapshot.selectedWorkspaceId?.uuidString ?? "")
        ])
#endif
        if autoWelcomeIfNeeded && select && !UserDefaults.standard.bool(forKey: WelcomeSettings.shownKey) {
            if let appDelegate = AppDelegate.shared {
                appDelegate.sendWelcomeCommandWhenReady(to: newWorkspace, markShownOnSend: true)
            } else {
                sendWelcomeWhenReady(to: newWorkspace)
            }
        } else if autoWelcomeIfNeeded && select && DefaultGridSettings.isEnabled() {
            // Welcome already ran (or is disabled): every subsequent new
            // workspace gets the monitor-classed default grid when enabled.
            if let appDelegate = AppDelegate.shared {
                appDelegate.spawnDefaultGridWhenReady(to: newWorkspace)
            } else {
                spawnDefaultGridWhenReady(to: newWorkspace)
            }
        }
        return newWorkspace
    }

    @MainActor
    private func sendWelcomeWhenReady(to workspace: Workspace) {
        if let terminalTab = workspace.focusedTerminalTab,
           terminalTab.surface.surface != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
                WelcomeSettings.performQuadLayout(on: workspace, initialPanel: terminalTab)
            }
            return
        }

        var resolved = false
        var readyObserver: NSObjectProtocol?
        var panelsCancellable: AnyCancellable?

        func finishIfReady() {
            guard !resolved,
                  let terminalTab = workspace.focusedTerminalTab,
                  terminalTab.surface.surface != nil else { return }
            resolved = true
            if let readyObserver {
                NotificationCenter.default.removeObserver(readyObserver)
            }
            panelsCancellable?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
                WelcomeSettings.performQuadLayout(on: workspace, initialPanel: terminalTab)
            }
        }

        panelsCancellable = workspace.$panels
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in
                    finishIfReady()
                }
            }
        readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  workspaceId == workspace.id else { return }
            Task { @MainActor in
                finishIfReady()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            Task { @MainActor in
                if let readyObserver, !resolved {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if !resolved {
                    panelsCancellable?.cancel()
                }
            }
        }
    }

    @MainActor
    private func spawnDefaultGridWhenReady(to workspace: Workspace) {
        func performGrid(_ initialTab: TerminalTab) {
            DefaultGridSettings.performDefaultGrid(
                on: workspace,
                initialPanel: initialTab
            )
        }

        if let terminalTab = workspace.focusedTerminalTab,
           terminalTab.surface.surface != nil {
            performGrid(terminalTab)
            return
        }

        var resolved = false
        var readyObserver: NSObjectProtocol?
        var panelsCancellable: AnyCancellable?

        func finishIfReady() {
            guard !resolved,
                  let terminalTab = workspace.focusedTerminalTab,
                  terminalTab.surface.surface != nil else { return }
            resolved = true
            if let readyObserver {
                NotificationCenter.default.removeObserver(readyObserver)
            }
            panelsCancellable?.cancel()
            performGrid(terminalTab)
        }

        panelsCancellable = workspace.$panels
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in
                    finishIfReady()
                }
            }
        readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  workspaceId == workspace.id else { return }
            Task { @MainActor in
                finishIfReady()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            Task { @MainActor in
                if let readyObserver, !resolved {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if !resolved {
                    panelsCancellable?.cancel()
                }
            }
        }
    }

    private func scheduleInitialWorkspaceGitMetadataRefresh(
        workspaceId: UUID,
        panelId: UUID,
        directory: String
    ) {
        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: Self.initialWorkspaceGitProbeDelays,
            reason: "initial"
        )
    }

    private func scheduleWorkspaceGitMetadataRefresh(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        delays: [TimeInterval],
        reason: String
    ) {
        let normalizedDirectory = normalizeDirectory(directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let generation = UUID()
        cancelWorkspaceGitProbeTimers(for: key)
        workspaceGitProbeGenerationByKey[key] = generation

#if DEBUG
        dlog(
            "workspace.gitProbe.schedule workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) dir=\(normalizedDirectory) reason=\(reason)"
        )
#endif

        var timers: [DispatchSourceTimer] = []
        for (index, delay) in delays.enumerated() {
            let isLastAttempt = index == delays.count - 1
            let timer = DispatchSource.makeTimerSource(queue: initialWorkspaceGitProbeQueue)
            timer.schedule(deadline: .now() + delay, repeating: .never)
            timer.setEventHandler { [weak self] in
                let snapshot = Self.initialWorkspaceGitMetadataSnapshot(for: normalizedDirectory)
                Task { @MainActor [weak self] in
                    self?.applyWorkspaceGitMetadataSnapshot(
                        snapshot,
                        generation: generation,
                        probeKey: key,
                        expectedDirectory: normalizedDirectory,
                        isLastAttempt: isLastAttempt
                    )
                }
            }
            timers.append(timer)
            timer.resume()
        }
        workspaceGitProbeTimersByKey[key] = timers
    }

    private func cancelWorkspaceGitProbeTimers(for key: WorkspaceGitProbeKey) {
        guard let timers = workspaceGitProbeTimersByKey.removeValue(forKey: key) else {
            return
        }
        for timer in timers {
            timer.setEventHandler {}
            timer.cancel()
        }
    }

    private func clearWorkspaceGitProbe(_ key: WorkspaceGitProbeKey) {
        workspaceGitProbeGenerationByKey.removeValue(forKey: key)
        cancelWorkspaceGitProbeTimers(for: key)
    }

    private func clearWorkspaceGitProbes(workspaceId: UUID) {
        let keys = Set(workspaceGitProbeGenerationByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitProbeTimersByKey.keys.filter { $0.workspaceId == workspaceId })
        for key in keys {
            clearWorkspaceGitProbe(key)
        }
    }

    private func applyWorkspaceGitMetadataSnapshot(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot,
        generation: UUID,
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool
    ) {
        defer {
            if shouldStopWorkspaceGitMetadataRefresh(snapshot) || isLastAttempt,
               workspaceGitProbeGenerationByKey[probeKey] == generation {
                clearWorkspaceGitProbe(probeKey)
            }
        }

        guard workspaceGitProbeGenerationByKey[probeKey] == generation else { return }
        guard let workspace = workspaces.first(where: { $0.id == probeKey.workspaceId }) else {
            clearWorkspaceGitProbe(probeKey)
            return
        }
        guard workspace.panels[probeKey.panelId] != nil else {
            clearWorkspaceGitProbe(probeKey)
            return
        }

        guard let currentDirectory = gitProbeDirectory(for: workspace, panelId: probeKey.panelId) else {
            clearWorkspaceGitProbe(probeKey)
            return
        }
        if currentDirectory != expectedDirectory {
            clearWorkspaceGitProbe(probeKey)
#if DEBUG
            dlog(
                "workspace.gitProbe.skip workspace=\(probeKey.workspaceId.uuidString.prefix(5)) " +
                "panel=\(probeKey.panelId.uuidString.prefix(5)) reason=directoryChanged " +
                "expected=\(expectedDirectory) current=\(currentDirectory)"
            )
#endif
            return
        }

        workspace.updateTabDirectory(panelId: probeKey.panelId, directory: expectedDirectory)

        let nextBranch = snapshot.branch
        if let nextBranch {
            workspace.updateTabGitBranch(
                panelId: probeKey.panelId,
                branch: nextBranch,
                isDirty: snapshot.isDirty
            )
        } else {
            workspace.clearTabGitBranch(panelId: probeKey.panelId)
        }

        switch snapshot.pullRequest {
        case .resolved(let pullRequest):
            workspace.updateTabPullRequest(
                panelId: probeKey.panelId,
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                checks: pullRequest.checks
            )
        case .notFound:
            if workspace.tabPullRequests[probeKey.panelId] != nil {
                workspace.clearTabPullRequest(panelId: probeKey.panelId)
            }
        case .unsupportedRepository, .transientFailure:
            break
        }

        // C11-104 — apply the resolved worktree+branch context.
        // Path:
        //   1. workspace.panelGitContexts (fast path for the sidebar).
        //   2. SurfaceMetadataStore.setInternal(.derived) for `worktree`
        //      and `branch` so external readers (c11 get-metadata,
        //      future Lattice queries) see the same data without
        //      reaching into Workspace internals.
        workspace.updateTabGitContext(
            panelId: probeKey.panelId,
            context: snapshot.gitContext
        )
        applyDerivedWorktreeBranchMetadata(
            workspaceId: probeKey.workspaceId,
            surfaceId: probeKey.panelId,
            context: snapshot.gitContext
        )

#if DEBUG
        let branchLabel = snapshot.branch ?? "none"
        let prLabel: String = {
            switch snapshot.pullRequest {
            case .unsupportedRepository:
                return "unsupported"
            case .notFound:
                return "none"
            case .transientFailure:
                return "transientFailure"
            case .resolved(let pullRequest):
                let checks = pullRequest.checks?.rawValue ?? "none"
                return "#\(pullRequest.number):\(pullRequest.status.rawValue):\(checks)"
            }
        }()
        dlog(
            "workspace.gitProbe.apply workspace=\(probeKey.workspaceId.uuidString.prefix(5)) " +
            "panel=\(probeKey.panelId.uuidString.prefix(5)) branch=\(branchLabel) dirty=\(snapshot.isDirty ? 1 : 0) " +
            "pr=\(prLabel)"
        )
#endif
    }

    private func shouldStopWorkspaceGitMetadataRefresh(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot
    ) -> Bool {
        switch snapshot.pullRequest {
        case .transientFailure:
            return false
        case .unsupportedRepository, .notFound, .resolved:
            return true
        }
    }

    private nonisolated static func initialWorkspaceGitMetadataSnapshot(
        for directory: String
    ) -> InitialWorkspaceGitMetadataSnapshot {
        // C11-104 — resolve the worktree/branch chip context first.
        // Runs the same off-main probe queue; the resolver itself
        // shells out to `git rev-parse` with a bounded timeout. We
        // resolve here unconditionally because the resolver also
        // handles the "no git" case (returns nil) which we want to
        // capture even when the legacy branch probe also returns nil.
        //
        // (C11-106) Goes through `resolveCached` so repeat probes
        // against a stable HEAD don't re-shell to git. The cache is
        // keyed on `(cwd, mtime(headPath), mtime(superHeadPath?))`;
        // see `GitContextResolver.resolveCached` for the full policy
        // (linked worktrees, submodules, nil-result bypass, etc.).
        let gitContext = GitContextResolver.resolveCached(
            cwd: directory,
            cache: Self.gitContextResolverCache
        )

        let branch = normalizedBranchName(runGitCommand(directory: directory, arguments: ["branch", "--show-current"]))
        guard let branch else {
            return InitialWorkspaceGitMetadataSnapshot(
                branch: nil,
                isDirty: false,
                pullRequest: .notFound,
                gitContext: gitContext
            )
        }

        let statusOutput = runGitCommand(directory: directory, arguments: ["status", "--porcelain", "-uno"])
        let isDirty = !(statusOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let pullRequest = workspacePullRequestSnapshot(directory: directory, branch: branch)
        return InitialWorkspaceGitMetadataSnapshot(
            branch: branch,
            isDirty: isDirty,
            pullRequest: pullRequest,
            gitContext: gitContext
        )
    }

    private nonisolated static func runGitCommand(directory: String, arguments: [String]) -> String? {
        runCommand(
            directory: directory,
            executable: "git",
            arguments: arguments
        )
    }

    private nonisolated static func workspacePullRequestSnapshot(
        directory: String,
        branch: String
    ) -> WorkspacePullRequestSnapshot {
        guard let repoSlug = githubRepositorySlug(directory: directory) else {
            return .unsupportedRepository
        }

        let result = runCommandResult(
            directory: directory,
            executable: "gh",
            arguments: [
                "pr", "view", branch,
                "--repo", repoSlug,
                "--json", "number,state,url",
            ],
            timeout: workspacePullRequestProbeTimeout
        )

        guard let result else {
#if DEBUG
            dlog(
                "workspace.gitProbe.pr.fail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) status=nil"
            )
#endif
            return .transientFailure
        }

        guard !result.timedOut,
              result.executionError == nil,
              let exitStatus = result.exitStatus else {
#if DEBUG
            let statusText: String
            if result.timedOut {
                statusText = "timeout"
            } else if let executionError = result.executionError {
                statusText = "error=\(executionError)"
            } else {
                statusText = "unknown"
            }
            let stderr = debugLogSnippet(result.stderr) ?? "none"
            dlog(
                "workspace.gitProbe.pr.fail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) status=\(statusText) stderr=\(stderr)"
            )
#endif
            return .transientFailure
        }

        if exitStatus != 0 {
            let stderr = result.stderr ?? ""
            if prErrorIndicatesNoPullRequest(stderr) {
#if DEBUG
                dlog(
                    "workspace.gitProbe.pr.none dir=\(directory) branch=\(branch) " +
                    "repo=\(repoSlug) stderr=\(debugLogSnippet(stderr) ?? "none")"
                )
#endif
                return .notFound
            }
#if DEBUG
            dlog(
                "workspace.gitProbe.pr.fail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) status=exit=\(exitStatus) stderr=\(debugLogSnippet(stderr) ?? "none")"
            )
#endif
            return .transientFailure
        }

        let output = result.stdout ?? ""
        guard !output.isEmpty,
              let pullRequest = decodeJSON(GitHubPullRequestViewItem.self, from: output) else {
#if DEBUG
            dlog(
                "workspace.gitProbe.pr.parseFail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) output=\(debugLogSnippet(output) ?? "none")"
            )
#endif
            return .transientFailure
        }

        guard let status = pullRequestStatus(from: pullRequest.state),
              let url = URL(string: pullRequest.url) else {
#if DEBUG
            dlog(
                "workspace.gitProbe.pr.parseFail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) output=\(debugLogSnippet(output) ?? "none")"
            )
#endif
            return .transientFailure
        }

        let checks = status == .open
            ? pullRequestChecksStatus(number: pullRequest.number, directory: directory, repoSlug: repoSlug)
            : nil

#if DEBUG
        dlog(
            "workspace.gitProbe.pr.success dir=\(directory) branch=\(branch) " +
            "repo=\(repoSlug) number=\(pullRequest.number) state=\(status.rawValue) checks=\(checks?.rawValue ?? "none")"
        )
#endif
        return .resolved(
            SidebarPullRequestState(
                number: pullRequest.number,
                label: "PR",
                url: url,
                status: status,
                branch: branch,
                checks: checks
            )
        )
    }

    private nonisolated static func pullRequestChecksStatus(
        number: Int,
        directory: String,
        repoSlug: String
    ) -> SidebarPullRequestChecksStatus? {
        let result = runCommandResult(
            directory: directory,
            executable: "gh",
            arguments: [
                "pr", "checks", String(number),
                "--repo", repoSlug,
                "--json", "bucket,state"
            ],
            timeout: workspacePullRequestProbeTimeout
        )

        guard let result,
              !result.timedOut,
              result.executionError == nil,
              let output = result.stdout,
              let exitStatus = result.exitStatus,
              exitStatus == 0 || exitStatus == 8,
              let checks = decodeJSON([GitHubPullRequestCheckItem].self, from: output) else {
            return nil
        }

        var sawPending = false
        var sawPass = false

        for check in checks {
            let bucket = check.bucket?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let state = check.state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if isFailingCheckState(bucket: bucket, state: state) {
                return .fail
            }
            if isPendingCheckState(bucket: bucket, state: state) {
                sawPending = true
                continue
            }
            if isPassingCheckState(bucket: bucket, state: state) {
                sawPass = true
            }
        }

        if sawPending {
            return .pending
        }
        if sawPass {
            return .pass
        }
        return nil
    }

    private nonisolated static func pullRequestStatus(
        from rawState: String
    ) -> SidebarPullRequestStatus? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "OPEN":
            return .open
        case "MERGED":
            return .merged
        case "CLOSED":
            return .closed
        default:
            return nil
        }
    }

    private nonisolated static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func prErrorIndicatesNoPullRequest(_ text: String?) -> Bool {
        let normalized = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty else { return false }
        return normalized.contains("no pull requests found")
            || normalized.contains("no pull request found")
            || normalized.contains("no pull requests associated")
            || normalized.contains("no pull request associated")
    }

    private nonisolated static func isFailingCheckState(bucket: String?, state: String?) -> Bool {
        switch bucket ?? state ?? "" {
        case "fail", "failure", "failed", "error", "timed_out", "timedout",
             "cancel", "cancelled", "canceled", "action_required", "startup_failure":
            return true
        default:
            return false
        }
    }

    private nonisolated static func isPendingCheckState(bucket: String?, state: String?) -> Bool {
        switch bucket ?? state ?? "" {
        case "pending", "queued", "in_progress", "requested", "waiting", "expected":
            return true
        default:
            return false
        }
    }

    private nonisolated static func isPassingCheckState(bucket: String?, state: String?) -> Bool {
        switch bucket ?? state ?? "" {
        case "pass", "success", "successful", "completed", "neutral", "skipping", "skipped":
            return true
        default:
            return false
        }
    }

    private nonisolated static func runCommand(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) -> String? {
        let result = runCommandResult(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
        guard let result,
              result.exitStatus == 0,
              !result.timedOut else {
            return nil
        }
        return result.stdout
    }

    private nonisolated static func runCommandResult(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) -> CommandResult? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = stdout
        process.standardError = stderr

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
        } catch {
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: String(describing: error)
            )
        }

        if let timeout,
           completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 0.2)
            }
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: true,
                executionError: nil
            )
        } else if timeout == nil {
            completion.wait()
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            stdout: String(data: stdoutData, encoding: .utf8),
            stderr: String(data: stderrData, encoding: .utf8),
            exitStatus: process.terminationStatus,
            timedOut: false,
            executionError: nil
        )
    }

    private nonisolated static func githubRepositorySlug(directory: String) -> String? {
        guard let remoteURL = runGitCommand(
            directory: directory,
            arguments: ["remote", "get-url", "origin"]
        ) else {
            return nil
        }

        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let githubPrefixes = [
            "git@github.com:",
            "ssh://git@github.com/",
            "https://github.com/",
            "http://github.com/",
            "git://github.com/",
        ]
        for prefix in githubPrefixes where trimmed.hasPrefix(prefix) {
            let path = String(trimmed.dropFirst(prefix.count))
            return normalizedGitHubRepositorySlug(path)
        }

        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host == "github.com" else {
            return nil
        }

        return normalizedGitHubRepositorySlug(url.path)
    }

    private nonisolated static func normalizedGitHubRepositorySlug(_ rawPath: String) -> String? {
        let trimmedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else { return nil }
        let components = trimmedPath.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo.removeLast(4)
        }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)"
    }

    private nonisolated static func debugLogSnippet(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(180))
    }

    private nonisolated static func normalizedBranchName(_ branch: String?) -> String? {
        let trimmed = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func requestBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard !pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.insert(workspaceId)
        pendingBackgroundWorkspaceLoadIds = updated
    }

    func completeBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        pendingBackgroundWorkspaceLoadIds = updated
    }

    func retainDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.formUnion(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    func releaseDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.subtract(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    func pruneBackgroundWorkspaceLoads(existingIds: Set<UUID>) {
        let pruned = pendingBackgroundWorkspaceLoadIds.intersection(existingIds)
        if pruned != pendingBackgroundWorkspaceLoadIds {
            pendingBackgroundWorkspaceLoadIds = pruned
        }
        let retained = debugPinnedWorkspaceLoadIds.intersection(existingIds)
        if retained != debugPinnedWorkspaceLoadIds {
            debugPinnedWorkspaceLoadIds = retained
        }
    }

    // Keep addTab as convenience alias
    @discardableResult
    func addTab(select: Bool = true, eagerLoadTerminal: Bool = false) -> Workspace {
        addWorkspace(select: select, eagerLoadTerminal: eagerLoadTerminal)
    }

    func terminalTabForWorkspaceConfigInheritanceSource() -> TerminalTab? {
        terminalTabForWorkspaceConfigInheritanceSource(snapshot: workspaceCreationSnapshot())
    }

    private func workspaceCreationSnapshot() -> WorkspaceCreationSnapshot {
        WorkspaceCreationSnapshot(
            workspaces: workspaces,
            selectedWorkspaceId: selectedWorkspaceId
        )
    }

    private func terminalTabForWorkspaceConfigInheritanceSource(
        snapshot: WorkspaceCreationSnapshot
    ) -> TerminalTab? {
        guard let workspace = snapshot.selectedWorkspace else { return nil }
        if let focusedTerminal = workspace.focusedTerminalTab {
            return focusedTerminal
        }
        if let rememberedTerminal = workspace.lastRememberedTerminalTabForConfigInheritance() {
            return rememberedTerminal
        }
        if let focusedPaneId = workspace.bonsplitController.focusedPaneId,
           let paneTerminal = workspace.terminalTabForConfigInheritance(inPane: focusedPaneId) {
            return paneTerminal
        }
        return workspace.terminalTabForConfigInheritance()
    }

    private func inheritedTerminalConfigForNewWorkspace() -> ghostty_surface_config_s? {
        inheritedTerminalConfigForNewWorkspace(snapshot: workspaceCreationSnapshot())
    }

    private func inheritedTerminalConfigForNewWorkspace(
        snapshot: WorkspaceCreationSnapshot
    ) -> ghostty_surface_config_s? {
        if let sourceSurface = terminalTabForWorkspaceConfigInheritanceSource(snapshot: snapshot)?.surface.surface {
            return cmuxInheritedSurfaceConfig(
                sourceSurface: sourceSurface,
                context: GHOSTTY_SURFACE_CONTEXT_TAB
            )
        }
        if let fallbackFontPoints = snapshot.selectedWorkspace?.lastRememberedTerminalFontPointsForConfigInheritance() {
            var config = ghostty_surface_config_new()
            config.font_size = fallbackFontPoints
            return config
        }
        return nil
    }

    private func normalizedWorkingDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let normalized = normalizeDirectory(directory)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalized
    }

    private func newTabInsertIndex(placementOverride: NewWorkspacePlacement? = nil) -> Int {
        newTabInsertIndex(snapshot: workspaceCreationSnapshot(), placementOverride: placementOverride)
    }

    private func newTabInsertIndex(
        snapshot: WorkspaceCreationSnapshot,
        placementOverride: NewWorkspacePlacement? = nil
    ) -> Int {
        let placement = placementOverride ?? WorkspacePlacementSettings.current()
        let pinnedCount = snapshot.workspaces.filter { $0.isPinned }.count
        let selectedIndex = snapshot.selectedWorkspaceId.flatMap { workspaceId in
            snapshot.workspaces.firstIndex(where: { $0.id == workspaceId })
        }
        let selectedIsPinned = selectedIndex.map { snapshot.workspaces[$0].isPinned } ?? false
        return WorkspacePlacementSettings.insertionIndex(
            placement: placement,
            selectedIndex: selectedIndex,
            selectedIsPinned: selectedIsPinned,
            pinnedCount: pinnedCount,
            totalCount: snapshot.workspaces.count
        )
    }

    private func preferredWorkingDirectoryForNewTab() -> String? {
        preferredWorkingDirectoryForNewTab(snapshot: workspaceCreationSnapshot())
    }

    private func preferredWorkingDirectoryForNewTab(
        snapshot: WorkspaceCreationSnapshot
    ) -> String? {
        guard let workspace = snapshot.selectedWorkspace else {
            return nil
        }
        // C11-238: drift never becomes a root. A new workspace starts in the
        // selected workspace's root, and auto-adoption sees that directory; the
        // focused shell's cwd is the fallback only when there is no usable root.
        if let root = Workspace.usableRootDirectory(workspace.rootDirectory) {
            return root
        }
        let focusedDirectory = workspace.focusedPanelId
            .flatMap { workspace.tabDirectories[$0] }
        let candidate = focusedDirectory ?? workspace.currentDirectory
        let normalized = normalizeDirectory(candidate)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalized
    }

    func moveWorkspaceToTop(_ workspaceId: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        guard index != 0 else { return }
        let workspace = workspaces.remove(at: index)
        let pinnedCount = workspaces.filter { $0.isPinned }.count
        let insertIndex = workspace.isPinned ? 0 : pinnedCount
        workspaces.insert(workspace, at: insertIndex)
    }

    func moveWorkspacesToTop(_ workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        let selectedTabs = workspaces.filter { workspaceIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let remainingTabs = workspaces.filter { !workspaceIds.contains($0.id) }
        let selectedPinned = selectedTabs.filter { $0.isPinned }
        let selectedUnpinned = selectedTabs.filter { !$0.isPinned }
        let remainingPinned = remainingTabs.filter { $0.isPinned }
        let remainingUnpinned = remainingTabs.filter { !$0.isPinned }
        workspaces = selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
    }

    func moveWorkspaceToTopForNotification(_ workspaceId: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let pinnedCount = workspaces.filter { $0.isPinned }.count
        guard index != pinnedCount else { return }
        let workspace = workspaces[index]
        guard !workspace.isPinned else { return }
        workspaces.remove(at: index)
        workspaces.insert(workspace, at: pinnedCount)
    }

    @discardableResult
    func reorderWorkspace(workspaceId: UUID, toIndex targetIndex: Int) -> Bool {
        guard let currentIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return false }
        if workspaces.count <= 1 { return true }

        let workspace = workspaces[currentIndex]
        let clamped = clampedReorderIndex(for: workspace, targetIndex: targetIndex)
        if currentIndex == clamped { return true }

        workspaces.remove(at: currentIndex)
        workspaces.insert(workspace, at: clamped)
        return true
    }

    @discardableResult
    func reorderWorkspace(workspaceId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil) -> Bool {
        guard workspaces.contains(where: { $0.id == workspaceId }) else { return false }
        if let beforeId {
            guard let idx = workspaces.firstIndex(where: { $0.id == beforeId }) else { return false }
            return reorderWorkspace(workspaceId: workspaceId, toIndex: idx)
        }
        if let afterId {
            guard let idx = workspaces.firstIndex(where: { $0.id == afterId }) else { return false }
            return reorderWorkspace(workspaceId: workspaceId, toIndex: idx + 1)
        }
        return false
    }

    func setCustomTitle(workspaceId: UUID, title: String?) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        workspaces[index].setCustomTitle(title)
        if selectedWorkspaceId == workspaceId {
            updateWindowTitle(for: workspaces[index])
        }
    }

    func clearCustomTitle(workspaceId: UUID) {
        setCustomTitle(workspaceId: workspaceId, title: nil)
    }

    func setWorkspaceColor(workspaceId: UUID, color: String?) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        workspace.setCustomColor(color)
    }

    func togglePin(workspaceId: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let workspace = workspaces[index]
        setPinned(workspace, pinned: !workspace.isPinned)
    }

    func setPinned(_ workspace: Workspace, pinned: Bool) {
        guard workspace.isPinned != pinned else { return }
        workspace.isPinned = pinned
        reorderTabForPinnedState(workspace)
    }

    private func reorderTabForPinnedState(_ workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces.remove(at: index)
        let pinnedCount = workspaces.filter { $0.isPinned }.count
        let insertIndex = min(pinnedCount, workspaces.count)
        workspaces.insert(workspace, at: insertIndex)
    }

    private func clampedReorderIndex(for workspace: Workspace, targetIndex: Int) -> Int {
        let clamped = max(0, min(targetIndex, workspaces.count - 1))
        let pinnedCount = workspaces.filter { $0.isPinned }.count
        if workspace.isPinned {
            return min(clamped, max(0, pinnedCount - 1))
        }
        return max(clamped, pinnedCount)
    }

    // MARK: - Surface Directory Updates (Backwards Compatibility)

    func updateSurfaceDirectory(workspaceId: UUID, surfaceId: UUID, directory: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        let previousDirectory = gitProbeDirectory(for: workspace, panelId: surfaceId)
        let normalized = normalizeDirectory(directory)
        workspace.updateTabDirectory(panelId: surfaceId, directory: normalized)
        workspace.adoptReportedDirectoryAsRootIfNeeded(panelId: surfaceId, directory: normalized)
        let nextDirectory = normalizedWorkingDirectory(normalized)
        if previousDirectory != nextDirectory {
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: workspaceId,
                panelId: surfaceId,
                reason: "directoryChange"
            )
        }
    }

    func updateSurfaceGitBranch(
        workspaceId: UUID,
        surfaceId: UUID,
        branch: String,
        isDirty: Bool
    ) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        let current = workspace.tabGitBranches[surfaceId]
        let normalizedBranch = Self.normalizedBranchName(branch) ?? branch
        guard current?.branch != normalizedBranch || current?.isDirty != isDirty else { return }
        workspace.updateTabGitBranch(panelId: surfaceId, branch: normalizedBranch, isDirty: isDirty)
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: surfaceId,
            reason: "branchChange"
        )
    }

    /// C11-104 — write the resolved worktree/branch labels into the
    /// surface manifest with source `.derived`. Called from the
    /// off-main probe apply step (already on the main actor via the
    /// Task hop in `scheduleWorkspaceGitMetadataRefresh`). External
    /// callers should NOT invoke this directly — it's keyed off the
    /// resolver output.
    private func applyDerivedWorktreeBranchMetadata(
        workspaceId: UUID,
        surfaceId: UUID,
        context: ResolvedGitContext?
    ) {
        let store = TabMetadataStore.shared

        guard let context else {
            store.setInternal(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                key: MetadataKey.worktree,
                value: "",
                source: .derived
            )
            store.setInternal(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                key: MetadataKey.branch,
                value: "",
                source: .derived
            )
            return
        }

        let worktreeValue: String
        switch context.outer {
        case .mainCheckout:
            worktreeValue = ""
        case .linkedWorktree(let basename, _, _):
            worktreeValue = basename
        case .notInRepo, .stale:
            // (C11-106) Both states clear the worktree value. Same
            // observable result as the nil-context branch handled
            // above; the explicit cases compile-check that future
            // enum additions are considered here too.
            worktreeValue = ""
        }

        let branchValue: String
        switch context.outer {
        case .mainCheckout(let branch), .linkedWorktree(_, _, let branch):
            switch branch {
            case .attached(let name): branchValue = name
            case .detached(let sha):  branchValue = "(detached @ \(sha))"
            case .noBranch:           branchValue = ""
            }
        case .notInRepo, .stale:
            branchValue = ""
        }

        store.setInternal(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            key: MetadataKey.worktree,
            value: worktreeValue,
            source: .derived
        )
        store.setInternal(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            key: MetadataKey.branch,
            value: branchValue,
            source: .derived
        )
    }

    func clearSurfaceGitBranch(workspaceId: UUID, surfaceId: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        let hadBranch = workspace.tabGitBranches[surfaceId] != nil
        let hadPullRequest = workspace.tabPullRequests[surfaceId] != nil
        guard hadBranch || hadPullRequest else { return }
        workspace.clearTabGitBranch(panelId: surfaceId)
        workspace.clearTabPullRequest(panelId: surfaceId)
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: surfaceId,
            reason: "branchCleared"
        )
    }

    func updateSurfaceShellActivity(
        workspaceId: UUID,
        surfaceId: UUID,
        state: Workspace.TabShellActivityState
    ) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        workspace.updateTabShellActivityState(panelId: surfaceId, state: state)
    }

    private func normalizeDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            if !url.path.isEmpty {
                return url.path
            }
        }
        return trimmed
    }

    /// C11-134: global per-type surface counts across all workspaces, merged
    /// into lifecycle breadcrumbs so Sentry hang reports carry workspace
    /// shape. Counts only — never titles or URLs.
    private func surfaceShapeSummary(tabCount: Int) -> [String: Any] {
        var counts = TabShapeCounts()
        for workspace in workspaces {
            for panel in workspace.panels.values {
                switch panel.panelType {
                case .terminal: counts.terminals += 1
                case .browser: counts.browsers += 1
                case .markdown: counts.markdown += 1
                }
            }
        }
        return [
            "tabCount": tabCount,
            "terminals": counts.terminals,
            "browsers": counts.browsers,
            "markdown": counts.markdown,
        ]
    }

    func closeWorkspace(_ workspace: Workspace) {
        guard workspaces.count > 1 else { return }
        sentryBreadcrumb("workspace.close", data: surfaceShapeSummary(tabCount: workspaces.count - 1))
        clearWorkspaceGitProbes(workspaceId: workspace.id)
        sidebarSelectedWorkspaceIds.remove(workspace.id)

        AppDelegate.shared?.notificationStore?.clearNotifications(forWorkspaceId: workspace.id)
        workspace.teardownAllPanels()
        workspace.teardownRemoteConnection()
        unwireClosedBrowserTracking(for: workspace)
        workspace.owningWorkspaceManager = nil

        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces.remove(at: index)

            if selectedWorkspaceId == workspace.id {
                // Keep the "focused index" stable when possible:
                // - If we closed workspace i and there is still a workspace at index i, focus it (the one that moved up).
                // - Otherwise (we closed the last workspace), focus the new last workspace (i-1).
                let newIndex = min(index, max(0, workspaces.count - 1))
                selectedWorkspaceId = workspaces[newIndex].id
            }
        }
    }

    /// Detach a workspace from this window without closing its panels.
    /// Used by the socket API for cross-window moves.
    @discardableResult
    func detachWorkspace(workspaceId: UUID) -> Workspace? {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return nil }
        clearWorkspaceGitProbes(workspaceId: workspaceId)
        sidebarSelectedWorkspaceIds.remove(workspaceId)

        let removed = workspaces.remove(at: index)
        unwireClosedBrowserTracking(for: removed)
        removed.owningWorkspaceManager = nil
        lastFocusedTabByWorkspace.removeValue(forKey: removed.id)

        if workspaces.isEmpty {
            // The UI assumes each window always has at least one workspace.
            _ = addWorkspace()
            return removed
        }

        if selectedWorkspaceId == removed.id {
            let nextIndex = min(index, max(0, workspaces.count - 1))
            selectedWorkspaceId = workspaces[nextIndex].id
        }

        return removed
    }

    /// Attach an existing workspace to this window.
    func attachWorkspace(_ workspace: Workspace, at index: Int? = nil, select: Bool = true) {
        workspace.owningWorkspaceManager = self
        wireClosedBrowserTracking(for: workspace)
        let insertIndex: Int = {
            guard let index else { return workspaces.count }
            return max(0, min(index, workspaces.count))
        }()
        workspaces.insert(workspace, at: insertIndex)
        if select {
            selectedWorkspaceId = workspace.id
        }
    }

    // Keep closeTab as convenience alias

    func closeCurrentWorkspace() {
        guard let selectedId = selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedId }) else { return }
        closeWorkspace(workspace)
    }

    func closeCurrentPanelWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closeTabInvocations")
#endif
        guard let selectedId = selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedId }),
              let focusedPanelId = workspace.focusedPanelId else { return }
        closePanelWithConfirmation(workspace: workspace, panelId: focusedPanelId)
    }

    func canCloseOtherTabsInFocusedPane() -> Bool {
        closeOtherTabsInFocusedAreaPlan() != nil
    }

    func closeOtherTabsInFocusedPaneWithConfirmation() {
        guard let plan = closeOtherTabsInFocusedAreaPlan() else { return }

        let count = plan.panelIds.count
        let titleLines = plan.titles.map { "• \($0)" }.joined(separator: "\n")
        let message = count == 1
            ? String(
                format: String(localized: "dialog.closeOtherTabs.message.one", defaultValue: "This closes 1 tab in this area:\n%@"),
                titleLines
            )
            : String(
                format: String(localized: "dialog.closeOtherTabs.message.other", defaultValue: "This closes %1$lld tabs in this area:\n%2$@"),
                count,
                titleLines
            )
        guard confirmClose(
            title: String(localized: "dialog.closeOtherTabs.title", defaultValue: "Close other tabs?"),
            message: message,
            acceptCmdD: false
        ) else { return }

        for panelId in plan.panelIds {
            _ = plan.workspace.closeTab(panelId, force: true)
        }
    }

    func closeCurrentWorkspaceWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closeTabInvocations")
#endif
        let sidebarSelectionIds = orderedSidebarSelectedWorkspaceIds()
        if sidebarSelectionIds.count > 1 {
            closeWorkspacesWithConfirmation(sidebarSelectionIds, allowPinned: true)
            return
        }
        guard let selectedId = selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedId }) else { return }
        closeWorkspaceWithConfirmation(workspace)
    }

    func closeWorkspaceWithConfirmation(_ workspace: Workspace) {
        closeWorkspaceIfRunningProcess(workspace)
    }

    func closeWorkspaceWithConfirmation(workspaceId: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        closeWorkspaceWithConfirmation(workspace)
    }

    func setSidebarSelectedWorkspaceIds(_ workspaceIds: Set<UUID>) {
        let existingIds = Set(workspaces.map(\.id))
        sidebarSelectedWorkspaceIds = workspaceIds.intersection(existingIds)
    }

    func closeWorkspacesWithConfirmation(_ workspaceIds: [UUID], allowPinned: Bool) {
        let workspaces = orderedClosableWorkspaces(workspaceIds, allowPinned: allowPinned)
        guard !workspaces.isEmpty else { return }
        guard workspaces.count > 1 else {
            closeWorkspaceWithConfirmation(workspaces[0])
            return
        }

        let plan = closeWorkspacesPlan(for: workspaces)
        // Test seam: synchronous handler short-circuits the overlay flow so
        // unit tests can exercise the multi-close path without a window.
        if let handler = workspaceCloseConfirmationHandler {
            guard handler(plan.title, plan.message) else { return }
            for workspace in plan.workspaces where self.workspaces.contains(where: { $0.id == workspace.id }) {
                closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            }
            return
        }
        // Anchor on the currently-displayed workspace so the overlay always
        // mounts on a visible content area. Off-screen workspaces are
        // isHidden=true (perf #127); their anchor view doesn't report a
        // window-coord frame, so mounting on one strands the runtime active
        // with no card visible (operator sees a no-op). The plan listing in
        // `plan.message` names every workspace being closed, so anchoring
        // away from the close set doesn't lose context. Fall back to the
        // first workspace in the close set only when there's no selection
        // at all.
        let host: Workspace? = selectedWorkspace ?? workspaces.first
        guard let host else { return }
        Task { @MainActor [weak self] in
            let accepted = await host.presentConfirmCloseWorkspace(
                title: plan.title,
                message: plan.message,
                source: .local
            )
            guard accepted, let self else { return }
            for workspace in plan.workspaces where self.workspaces.contains(where: { $0.id == workspace.id }) {
                self.closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            }
        }
    }

    func selectWorkspace(_ workspace: Workspace) {
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("select", to: workspace.id)
#endif
        selectedWorkspaceId = workspace.id
    }


    private func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        if let confirmCloseHandler {
            return confirmCloseHandler(title, message, acceptCmdD)
        }
        _ = acceptCmdD

        // Cancel is the first button, so Return and Escape both keep things
        // open; closing takes a click.
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
            .hasDestructiveAction = true

        // C11-196: `NSApp.activationPolicy()` is a synchronous LaunchServices XPC
        // round trip; read the policy c11 itself set instead.
        if AppPresentationPolicy.effectiveActivationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }

        return alert.runModal() == .alertSecondButtonReturn
    }

    private struct CloseOtherTabsInFocusedAreaPlan {
        let workspace: Workspace
        let panelIds: [UUID]
        let titles: [String]
    }

    private struct CloseWorkspacesPlan {
        let workspaces: [Workspace]
        let title: String
        let message: String
    }

    private func closeOtherTabsInFocusedAreaPlan() -> CloseOtherTabsInFocusedAreaPlan? {
        guard let workspace = selectedWorkspace else { return nil }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }

        let bonsplitTabsInPane = workspace.bonsplitController.tabs(inPane: paneId)
        guard !bonsplitTabsInPane.isEmpty else { return nil }
        guard let selectedBonsplitTabId = workspace.bonsplitController.selectedTab(inPane: paneId)?.id ?? bonsplitTabsInPane.first?.id else {
            return nil
        }

        var targetPanelIds: [UUID] = []
        var targetTitles: [String] = []
        for bonsplitTab in bonsplitTabsInPane where bonsplitTab.id != selectedBonsplitTabId {
            guard let panelId = workspace.tabIdFromBonsplitTabId(bonsplitTab.id) else { continue }
            if workspace.isTabPinned(panelId) {
                continue
            }
            targetPanelIds.append(panelId)
            targetTitles.append(closeOtherTabsDisplayTitle(workspace.tabTitle(panelId: panelId)))
        }

        guard !targetPanelIds.isEmpty else { return nil }
        return CloseOtherTabsInFocusedAreaPlan(
            workspace: workspace,
            panelIds: targetPanelIds,
            titles: targetTitles
        )
    }

    private func closeOtherTabsDisplayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty {
            return collapsed
        }
        return "Untitled Tab"
    }

    private func orderedClosableWorkspaces(_ workspaceIds: [UUID], allowPinned: Bool) -> [Workspace] {
        let targetIds = Set(workspaceIds)
        return workspaces.compactMap { workspace in
            guard targetIds.contains(workspace.id) else { return nil }
            guard allowPinned || !workspace.isPinned else { return nil }
            return workspace
        }
    }

    private func orderedSidebarSelectedWorkspaceIds() -> [UUID] {
        workspaces.compactMap { workspace in
            sidebarSelectedWorkspaceIds.contains(workspace.id) ? workspace.id : nil
        }
    }

    private func closeWorkspacesPlan(for workspaces: [Workspace]) -> CloseWorkspacesPlan {
        let willCloseWindow = workspaces.count == self.workspaces.count
        let title = willCloseWindow
            ? String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
            : String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        let titleLines = workspaces
            .map { "• \(closeWorkspaceDisplayTitle($0.title))" }
            .joined(separator: "\n")
        let format = willCloseWindow
            ? String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their areas:\n%2$@"
            )
            : String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their areas:\n%2$@"
            )
        let message = String(format: format, locale: .current, Int64(workspaces.count), titleLines)
        return CloseWorkspacesPlan(
            workspaces: workspaces,
            title: title,
            message: message
        )
    }

    private func closeWorkspaceDisplayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty {
            return collapsed
        }
        return String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
    }

    private func closeWorkspaceIfRunningProcess(_ workspace: Workspace, requiresConfirmation: Bool = true) {
        if requiresConfirmation, workspaceNeedsConfirmClose(workspace) {
            let title = String(
                localized: "dialog.closeWorkspace.title",
                defaultValue: "Close workspace?"
            )
            let displayName = closeWorkspaceDisplayTitle(workspace.title)
            let format = String(
                localized: "dialog.closeWorkspace.messageNamed",
                defaultValue: "This will close the workspace \u{201C}%@\u{201D} and all of its areas."
            )
            let message = String(format: format, locale: .current, displayName)
            // Off-screen workspaces are isHidden=true (perf #127), so their anchor
            // view doesn't report a window-coord frame and the overlay would bail
            // on `guard let anchor`. When the operator clicks the X on a background
            // tab we first switch selection to that workspace so it becomes the
            // visible one; the confirm card then mounts on the workspace being
            // closed, matching what the dialog references. (C11-117)
            if selectedWorkspaceId != workspace.id {
                selectWorkspace(workspace)
            }
            // Test seam: synchronous handler short-circuits the overlay flow so
            // unit tests can exercise the close path without a window.
            if let handler = workspaceCloseConfirmationHandler {
                guard handler(title, message) else { return }
                finishCloseWorkspace(workspace)
                return
            }
            // Workspace-scoped overlay: a near-black scrim covering the workspace
            // content area only, with a centered confirm/cancel card. Lands above
            // portal-hosted terminal/browser content via themeFrame mount. Sidebar
            // stays visible. Plan §3.1, §3.3.
            Task { @MainActor [weak self, weak workspace] in
                guard let self, let workspace else { return }
                let accepted = await workspace.presentConfirmCloseWorkspace(
                    title: title,
                    message: message,
                    source: .local
                )
                guard accepted else { return }
                // Acceptance-time revalidation — workspace may have closed or
                // been destroyed while the overlay was visible.
                guard self.workspaces.contains(where: { $0.id == workspace.id }) else { return }
                self.finishCloseWorkspace(workspace)
            }
            return
        }
        finishCloseWorkspace(workspace)
    }

    @MainActor
    private func finishCloseWorkspace(_ workspace: Workspace) {
        if workspaces.count <= 1 {
            // Last workspace in this window: close the window (Cmd+Shift+W behavior).
            if let window {
                if let app = AppDelegate.shared {
                    app.closeMainWindowWithoutPrompt(window)
                } else {
                    window.performClose(nil)
                }
            } else {
                AppDelegate.shared?.closeMainWindowContainingWorkspaceId(workspace.id)
            }
        } else {
            closeWorkspace(workspace)
        }
    }

    private func shouldCloseWorkspaceOnLastSurfaceShortcut(_ workspace: Workspace, panelId: UUID) -> Bool {
        LastTabCloseShortcutSettings.closesWorkspace() &&
            workspace.panels.count <= 1 &&
            workspace.panels[panelId] != nil
    }

    private func closePanelWithConfirmation(workspace: Workspace, panelId: UUID) {
        guard workspace.panels[panelId] != nil else {
#if DEBUG
            dlog(
                "surface.close.shortcut.skip tab=\(workspace.id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) reason=missingPanel"
            )
#endif
            return
        }

        let bonsplitTabCount = workspace.bonsplitController.allPaneIds.reduce(0) { partial, paneId in
            partial + workspace.bonsplitController.tabs(inPane: paneId).count
        }
        let panelKind: String = {
            guard let panel = workspace.panels[panelId] else { return "missing" }
            if panel is TerminalTab { return "terminal" }
            if panel is BrowserTab { return "browser" }
            return String(describing: type(of: panel))
        }()
        let closesWorkspaceOnLastSurfaceShortcut = shouldCloseWorkspaceOnLastSurfaceShortcut(workspace, panelId: panelId)
#if DEBUG
        dlog(
            "surface.close.shortcut.begin tab=\(workspace.id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) kind=\(panelKind) " +
            "panelCount=\(workspace.panels.count) bonsplitTabs=\(bonsplitTabCount) " +
            "closeWorkspaceOnLastSurface=\(closesWorkspaceOnLastSurfaceShortcut ? 1 : 0)"
        )
#endif

        // The last-surface shortcut preference only affects Cmd+W. The tab close button
        // continues to use Workspace's explicit-close path when it closes the last surface.
        if closesWorkspaceOnLastSurfaceShortcut,
           let surfaceId = workspace.bonsplitTabIdFromTabId(panelId) {
            workspace.markExplicitClose(bonsplitTabId: surfaceId)
        }
        let closed = workspace.closeTab(panelId)
#if DEBUG
        dlog(
            "surface.close.shortcut tab=\(workspace.id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) closed=\(closed ? 1 : 0) " +
            "panelsAfterCall=\(workspace.panels.count)"
        )
#endif
    }

    func closePanelWithConfirmation(workspaceId: UUID, surfaceId: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        closePanelWithConfirmation(workspace: workspace, panelId: surfaceId)
    }

    /// Runtime close requests from Ghostty should only ever target the specific surface.
    /// They must not escalate into workspace/window-close semantics for "last tab".
    func closeRuntimeSurfaceWithConfirmation(workspaceId: UUID, surfaceId: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        guard workspace.panels[surfaceId] != nil else { return }

        let needsConfirm = workspace.terminalPanel(for: surfaceId).map { terminalPanel in
            workspace.tabNeedsConfirmClose(
                panelId: surfaceId,
                fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()
            )
        } ?? false

        guard needsConfirm else {
            performCloseRuntimeSurface(workspace: workspace, surfaceId: surfaceId)
            return
        }

        guard AreaInteractionFeatureFlag.isEnabled else {
            // Legacy NSAlert path — kept as a rollback/fallback.
            guard confirmClose(
                title: String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
                message: String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab."),
                acceptCmdD: false
            ) else { return }
            performCloseRuntimeSurface(workspace: workspace, surfaceId: surfaceId)
            return
        }

        // Route the confirmation through the pane-interaction runtime so the
        // card anchors on the surface being closed. Ghostty can fire this
        // callback twice during a close race — dedupeToken collapses that.
        Task { @MainActor [weak self] in
            let accepted = await workspace.presentConfirmClose(
                panelId: surfaceId,
                title: String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
                message: String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab."),
                source: .local,
                dedupeToken: "ghostty.close_surface_cb.\(surfaceId.uuidString)"
            )
            guard accepted, let self else { return }
            // Acceptance-time revalidation: the user can take arbitrarily long
            // to accept. If the tab or panel was torn down in the meantime,
            // skip the close silently (plan §2).
            guard let currentTab = self.workspaces.first(where: { $0.id == workspaceId }),
                  currentTab.panels[surfaceId] != nil else { return }
            self.performCloseRuntimeSurface(workspace: currentTab, surfaceId: surfaceId)
        }
    }

    @MainActor
    private func performCloseRuntimeSurface(workspace: Workspace, surfaceId: UUID) {
        _ = workspace.closeTab(surfaceId, force: true)
        AppDelegate.shared?.notificationStore?.clearNotifications(forWorkspaceId: workspace.id, surfaceId: surfaceId)
    }

    /// Runtime close requests from Ghostty without confirmation (e.g. child-exit).
    /// This path must only close the addressed surface and must never close the workspace window.
    func closeRuntimeSurface(workspaceId: UUID, surfaceId: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        guard workspace.panels[surfaceId] != nil else { return }

#if DEBUG
        dlog(
            "surface.close.runtime tab=\(workspaceId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panelsBefore=\(workspace.panels.count)"
        )
#endif

        // Keep AppKit first responder in sync with workspace focus before routing the close.
        // If split reparenting caused a temporary model/view mismatch, fallback close logic in
        // Workspace.closePanel uses focused selection to resolve the correct tab deterministically.
        reconcileFocusedPanelFromFirstResponderForKeyboard()
        let closed = workspace.closeTab(surfaceId, force: true)
#if DEBUG
        dlog(
            "surface.close.runtime.done tab=\(workspaceId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) closed=\(closed ? 1 : 0) panelsAfter=\(workspace.panels.count)"
        )
#endif
        AppDelegate.shared?.notificationStore?.clearNotifications(forWorkspaceId: workspace.id, surfaceId: surfaceId)
    }

    /// Close a panel because its child process exited (e.g. the user hit Ctrl+D).
    ///
    /// This should never prompt: the process is already gone, and Ghostty emits the
    /// `SHOW_CHILD_EXITED` action specifically so the host app can decide what to do.
    func closePanelAfterChildExited(workspaceId: UUID, surfaceId: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        guard workspace.panels[surfaceId] != nil else { return }

#if DEBUG
        dlog(
            "surface.close.childExited tab=\(workspaceId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panels=\(workspace.panels.count) workspaces=\(workspaces.count)"
        )
#endif

        // Child-exit on the last panel should collapse the workspace, matching explicit close
        // semantics (and close the window when it was the last workspace).
        if workspace.panels.count <= 1 {
            if workspaces.count <= 1 {
                if let app = AppDelegate.shared {
                    app.notificationStore?.clearNotifications(forWorkspaceId: workspaceId)
                    app.closeMainWindowContainingWorkspaceId(workspaceId)
                } else {
                    // Headless/test fallback when no AppDelegate window context exists.
                    closeRuntimeSurface(workspaceId: workspaceId, surfaceId: surfaceId)
                }
            } else {
                closeWorkspace(workspace)
            }
            return
        }

        closeRuntimeSurface(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    private func workspaceNeedsConfirmClose(_ workspace: Workspace) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] == "1" {
            return true
        }
#endif
        return workspace.needsConfirmCloseWorkspace()
    }

    func titleForTab(_ workspaceId: UUID) -> String? {
        workspaces.first(where: { $0.id == workspaceId })?.title
    }

    // MARK: - Panel/Surface ID Access

    /// Returns the focused panel ID for a tab (replaces focusedSurfaceId)
    func focusedPanelId(for workspaceId: UUID) -> UUID? {
        workspaces.first(where: { $0.id == workspaceId })?.focusedPanelId
    }

    /// Returns the focused panel if it's a BrowserPanel, nil otherwise
    var focusedBrowserTab: BrowserTab? {
        guard let workspace = selectedWorkspace,
              let panelId = workspace.focusedPanelId else { return nil }
        return workspace.panels[panelId] as? BrowserTab
    }

    @discardableResult
    func zoomInFocusedBrowser() -> Bool {
        focusedBrowserTab?.zoomIn() ?? false
    }

    @discardableResult
    func zoomOutFocusedBrowser() -> Bool {
        focusedBrowserTab?.zoomOut() ?? false
    }

    @discardableResult
    func resetZoomFocusedBrowser() -> Bool {
        focusedBrowserTab?.resetZoom() ?? false
    }

    /// Returns the focused panel if it's a MarkdownPanel, nil otherwise
    var focusedMarkdownTab: MarkdownTab? {
        guard let workspace = selectedWorkspace,
              let panelId = workspace.focusedPanelId else { return nil }
        return workspace.panels[panelId] as? MarkdownTab
    }

    @discardableResult
    func zoomInFocusedMarkdown() -> Bool {
        focusedMarkdownTab?.zoomIn() ?? false
    }

    @discardableResult
    func zoomOutFocusedMarkdown() -> Bool {
        focusedMarkdownTab?.zoomOut() ?? false
    }

    @discardableResult
    func resetZoomFocusedMarkdown() -> Bool {
        focusedMarkdownTab?.resetZoom() ?? false
    }

    @discardableResult
    func toggleDeveloperToolsFocusedBrowser() -> Bool {
        focusedBrowserTab?.toggleDeveloperTools() ?? false
    }

    @discardableResult
    func showJavaScriptConsoleFocusedBrowser() -> Bool {
        focusedBrowserTab?.showDeveloperToolsConsole() ?? false
    }

    /// Backwards compatibility: returns the focused surface ID
    func focusedSurfaceId(for workspaceId: UUID) -> UUID? {
        focusedPanelId(for: workspaceId)
    }

    func rememberFocusedSurface(workspaceId: UUID, surfaceId: UUID) {
        lastFocusedTabByWorkspace[workspaceId] = surfaceId
    }

    func applyWindowBackgroundForSelectedTab() {
        guard let selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceId }),
              let terminalTab = workspace.focusedTerminalTab else { return }
        terminalTab.applyWindowBackgroundIfActive()
    }

    private func focusSelectedTabPanel(previousWorkspaceId: UUID?) {
#if DEBUG
        let phaseStart = CACurrentMediaTime()
        func phaseDlog(_ marker: String) {
            let dtMs = (CACurrentMediaTime() - phaseStart) * 1000
            let switchDtMs = debugWorkspaceSwitchStartTime > 0
                ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
                : 0
            dlog(
                "ws.focusPanel.\(marker) id=\(debugWorkspaceSwitchId) " +
                "phaseDt=\(Self.debugMsText(dtMs)) switchDt=\(Self.debugMsText(switchDtMs))"
            )
        }
        phaseDlog("enter")
        defer { phaseDlog("exit") }
#endif
        guard let selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceId }) else { return }

        // Try to restore previous focus
        if let restoredPanelId = lastFocusedTabByWorkspace[selectedWorkspaceId],
           workspace.panels[restoredPanelId] != nil,
           workspace.focusedPanelId != restoredPanelId {
            workspace.focusPanel(restoredPanelId)
        }

        // Focus the panel
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else { return }

        // Defer unfocusing the previous workspace's panel until ContentView confirms handoff
        // completion (new workspace has focus or timeout fallback), to avoid a visible freeze gap.
        if let previousWorkspaceId,
           let previousTab = workspaces.first(where: { $0.id == previousWorkspaceId }),
           let previousPanelId = previousTab.focusedPanelId,
           previousTab.panels[previousPanelId] != nil {
            replacePendingWorkspaceUnfocusTarget(
                with: (workspaceId: previousWorkspaceId, panelId: previousPanelId)
            )
        }
#if DEBUG
        phaseDlog("preFocus")
#endif

        panel.focus()
#if DEBUG
        phaseDlog("postTabFocus")
#endif

        // For terminal panels, ensure proper focus handling
        if let terminalTab = panel as? TerminalTab {
            terminalTab.hostedView.ensureFocus(for: selectedWorkspaceId, surfaceId: panelId)
#if DEBUG
            phaseDlog("postEnsureFocus")
#endif
        }
    }

    func completePendingWorkspaceUnfocus(reason: String) {
        guard let pending = pendingWorkspaceUnfocusTarget else { return }
        // If this tab became selected again before handoff completion, drop the stale
        // pending entry so it cannot be flushed later and deactivate the selected workspace.
        guard Self.shouldUnfocusPendingWorkspace(
            pendingWorkspaceId: pending.workspaceId,
            selectedWorkspaceId: selectedWorkspaceId
        ) else {
            pendingWorkspaceUnfocusTarget = nil
#if DEBUG
            dlog(
                "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(pending.workspaceId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=selected_again"
            )
#endif
            return
        }
        pendingWorkspaceUnfocusTarget = nil
        unfocusWorkspaceTab(workspaceId: pending.workspaceId, panelId: pending.panelId)
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.unfocus.complete id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(pending.workspaceId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        } else {
            dlog(
                "ws.unfocus.complete id=none tab=\(Self.debugShortWorkspaceId(pending.workspaceId)) " +
                "panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        }
#endif
    }

    private func replacePendingWorkspaceUnfocusTarget(with next: (workspaceId: UUID, panelId: UUID)) {
        if let current = pendingWorkspaceUnfocusTarget,
           current.workspaceId == next.workspaceId,
           current.panelId == next.panelId {
            return
        }

        if let current = pendingWorkspaceUnfocusTarget {
            // Never unfocus the currently selected workspace when replacing stale pending state.
            if Self.shouldUnfocusPendingWorkspace(
                pendingWorkspaceId: current.workspaceId,
                selectedWorkspaceId: selectedWorkspaceId
            ) {
                unfocusWorkspaceTab(workspaceId: current.workspaceId, panelId: current.panelId)
#if DEBUG
                dlog(
                    "ws.unfocus.flush tab=\(Self.debugShortWorkspaceId(current.workspaceId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced"
                )
#endif
            } else {
#if DEBUG
                dlog(
                    "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(current.workspaceId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced_selected"
                )
#endif
            }
        }

        pendingWorkspaceUnfocusTarget = next
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.unfocus.defer id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(next.workspaceId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        } else {
            dlog(
                "ws.unfocus.defer id=none tab=\(Self.debugShortWorkspaceId(next.workspaceId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        }
#endif
    }

    private func unfocusWorkspaceTab(workspaceId: UUID, panelId: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }),
              let panel = workspace.panels[panelId] else { return }
        panel.unfocus()
    }

    static func shouldUnfocusPendingWorkspace(pendingWorkspaceId: UUID, selectedWorkspaceId: UUID?) -> Bool {
        selectedWorkspaceId != pendingWorkspaceId
    }

    private func markFocusedPanelReadIfActive(workspaceId: UUID) {
        let shouldSuppressFlash = suppressFocusFlash
        suppressFocusFlash = false
        guard !shouldSuppressFlash else { return }
        guard AppFocusState.isAppActive() else { return }
        guard let panelId = focusedPanelId(for: workspaceId) else { return }
        markTabReadOnFocusIfActive(workspaceId: workspaceId, panelId: panelId)
    }

    private func markTabReadOnFocusIfActive(workspaceId: UUID, panelId: UUID) {
        guard selectedWorkspaceId == workspaceId else { return }
        guard !suppressFocusFlash else { return }
        guard AppFocusState.isAppActive() else { return }
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
        guard notificationStore.hasUnreadNotification(forWorkspaceId: workspaceId, surfaceId: panelId) else { return }
        if let workspace = workspaces.first(where: { $0.id == workspaceId }) {
            workspace.triggerNotificationFocusFlash(panelId: panelId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forWorkspaceId: workspaceId, surfaceId: panelId)
    }

    @discardableResult
    func dismissNotificationOnDirectInteraction(workspaceId: UUID, surfaceId: UUID?) -> Bool {
        guard selectedWorkspaceId == workspaceId else { return false }
        guard AppFocusState.isAppActive() else { return false }
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return false }
        guard notificationStore.hasUnreadNotification(forWorkspaceId: workspaceId, surfaceId: surfaceId) else { return false }
        if let panelId = surfaceId,
           let workspace = workspaces.first(where: { $0.id == workspaceId }) {
            workspace.triggerNotificationFocusFlash(panelId: panelId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forWorkspaceId: workspaceId, surfaceId: surfaceId)
        return true
    }

    private func enqueueTabTitleUpdate(workspaceId: UUID, panelId: UUID, title: String) {
        // OSC titles: pass through (including empty — empty OSC clears title when current source is osc).
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = TabTitleUpdateKey(workspaceId: workspaceId, panelId: panelId)
        pendingTabTitleUpdates[key] = trimmed
        panelTitleUpdateCoalescer.signal { [weak self] in
            self?.flushPendingPanelTitleUpdates()
        }
    }

    private func flushPendingPanelTitleUpdates() {
        guard !pendingTabTitleUpdates.isEmpty else { return }
        let updates = pendingTabTitleUpdates
        pendingTabTitleUpdates.removeAll(keepingCapacity: true)
        for (key, title) in updates {
            updateTabTitle(workspaceId: key.workspaceId, panelId: key.panelId, title: title)
        }
    }

    private func updateTabTitle(workspaceId: UUID, panelId: UUID, title: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }

        // M7: route OSC title through M2 metadata store with source: .osc.
        // The store's precedence gate drops the write if title is held by declare/explicit.
        var applied = false
        if title.isEmpty {
            do {
                let outcome = try TabMetadataStore.shared.clearMetadata(
                    workspaceId: workspace.id,
                    surfaceId: panelId,
                    keys: ["title"],
                    source: .osc
                )
                applied = outcome.applied["title"] ?? false
            } catch {
                applied = false
            }
        } else {
            do {
                let outcome = try TabMetadataStore.shared.setMetadata(
                    workspaceId: workspace.id,
                    surfaceId: panelId,
                    partial: ["title": title],
                    mode: .merge,
                    source: .osc
                )
                applied = outcome.applied["title"] ?? false
            } catch {
                applied = false
            }
        }
        guard applied else { return }

        workspace.syncTabTitleFromMetadata(panelId: panelId)

        if selectedWorkspaceId == workspaceId && workspace.focusedPanelId == panelId {
            updateWindowTitle(for: workspace)
        }
    }

    func focusedSurfaceTitleDidChange(workspaceId: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }),
              let focusedPanelId = workspace.focusedPanelId,
              let title = workspace.tabTitles[focusedPanelId] else { return }
        workspace.applyProcessTitle(title)
        if selectedWorkspaceId == workspaceId {
            updateWindowTitle(for: workspace)
        }
    }

    private func updateWindowTitleForSelectedTab() {
        guard let selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceId }) else {
            updateWindowTitle(for: nil)
            return
        }
        updateWindowTitle(for: workspace)
    }

    private func updateWindowTitle(for workspace: Workspace?) {
        let title = windowTitle(for: workspace)
        guard let targetWindow = window else { return }
        targetWindow.title = title
    }

    private func windowTitle(for workspace: Workspace?) -> String {
        guard let workspace else { return "cmux" }
        let trimmedTitle = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let trimmedDirectory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDirectory.isEmpty ? "cmux" : trimmedDirectory
    }

    func focusWorkspace(_ workspaceId: UUID, surfaceId: UUID? = nil, suppressFlash: Bool = false) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        if let surfaceId, workspace.panels[surfaceId] != nil {
            // Keep selected-surface intent stable across selectedTabId didSet async restore.
            lastFocusedTabByWorkspace[workspaceId] = surfaceId
        }
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("focus", to: workspaceId)
#endif
        selectedWorkspaceId = workspaceId
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.workspaceId: workspaceId]
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            if let app = AppDelegate.shared,
               let windowId = app.windowId(for: self),
               let window = app.mainWindow(for: windowId) {
                window.makeKeyAndOrderFront(nil)
            } else if let window = NSApp.keyWindow ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }

        if let surfaceId {
            if !suppressFlash {
                focusSurface(workspaceId: workspaceId, surfaceId: surfaceId)
            } else {
                workspace.focusPanel(surfaceId)
            }
        }
    }

    @discardableResult
    func focusTabFromNotification(_ workspaceId: UUID, surfaceId: UUID? = nil) -> Bool {
        let wasSelected = selectedWorkspaceId == workspaceId
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else {
#if DEBUG
            dlog("notification.focus.fail tab=\(workspaceId.uuidString.prefix(5)) reason=missingTab")
#endif
            return false
        }
        if let surfaceId, workspace.panels[surfaceId] == nil {
#if DEBUG
            dlog(
                "notification.focus.fail tab=\(workspaceId.uuidString.prefix(5)) " +
                "panel=\(surfaceId.uuidString.prefix(5)) reason=missingPanel"
            )
#endif
            return false
        }
        let desiredPanelId = surfaceId ?? workspace.focusedPanelId
#if DEBUG
        if let desiredPanelId {
            AppDelegate.shared?.armJumpUnreadFocusRecord(workspaceId: workspaceId, surfaceId: desiredPanelId)
        }
#endif
        // Jump-to-unread should reveal the destination pane instead of keeping an old split-zoom
        // state active around it.
        workspace.clearSplitZoom()
        suppressFocusFlash = true
        focusWorkspace(workspaceId, surfaceId: desiredPanelId, suppressFlash: true)
        if wasSelected {
            suppressFocusFlash = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  let workspace = self.workspaces.first(where: { $0.id == workspaceId }) else { return }
            let targetPanelId = desiredPanelId ?? workspace.focusedPanelId
            guard let targetPanelId,
                  workspace.panels[targetPanelId] != nil else { return }
            guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
            guard notificationStore.hasUnreadNotification(forWorkspaceId: workspaceId, surfaceId: targetPanelId) else { return }
            workspace.triggerNotificationFocusFlash(panelId: targetPanelId, requiresSplit: false, shouldFocus: true)
            notificationStore.markRead(forWorkspaceId: workspaceId, surfaceId: targetPanelId)
        }
        return true
    }

    func focusSurface(workspaceId: UUID, surfaceId: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        workspace.focusPanel(surfaceId)
    }

    func selectNextWorkspace() {
        guard let currentId = selectedWorkspaceId,
              let currentIndex = workspaces.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % workspaces.count
#if DEBUG
        let nextId = workspaces[nextIndex].id
        debugPrepareWorkspaceSwitch("next", from: currentId, to: nextId)
#endif
        activateWorkspaceCycleHotWindow()
        selectedWorkspaceId = workspaces[nextIndex].id
    }

    func selectPreviousWorkspace() {
        guard let currentId = selectedWorkspaceId,
              let currentIndex = workspaces.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + workspaces.count) % workspaces.count
#if DEBUG
        let prevId = workspaces[prevIndex].id
        debugPrepareWorkspaceSwitch("prev", from: currentId, to: prevId)
#endif
        activateWorkspaceCycleHotWindow()
        selectedWorkspaceId = workspaces[prevIndex].id
    }

    private func activateWorkspaceCycleHotWindow() {
        workspaceCycleGeneration &+= 1
        let generation = workspaceCycleGeneration
#if DEBUG
        let switchId = debugWorkspaceSwitchId
        let switchDtMs = debugWorkspaceSwitchStartTime > 0
            ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
            : 0
#endif
        if !isWorkspaceCycleHot {
            isWorkspaceCycleHot = true
#if DEBUG
            dlog(
                "ws.hot.on id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
        }

        let hadPendingCooldown = workspaceCycleCooldownTask != nil
        workspaceCycleCooldownTask?.cancel()
#if DEBUG
        if hadPendingCooldown {
            dlog(
                "ws.hot.cancelPrev id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
        }
#endif
        workspaceCycleCooldownTask = Task { [weak self, generation] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
#if DEBUG
                await MainActor.run {
                    guard let self else { return }
                    let dtMs = self.debugWorkspaceSwitchStartTime > 0
                        ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                        : 0
                    dlog(
                        "ws.hot.cooldownCanceled id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                    )
                }
#endif
                return
            }
            await MainActor.run {
                guard let self else { return }
                guard self.workspaceCycleGeneration == generation else { return }
#if DEBUG
                let dtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                dlog(
                    "ws.hot.off id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                )
#endif
                self.isWorkspaceCycleHot = false
                self.workspaceCycleCooldownTask = nil
            }
        }
    }

#if DEBUG
    func debugCurrentWorkspaceSwitchSnapshot() -> (id: UInt64, startedAt: CFTimeInterval)? {
        guard debugWorkspaceSwitchId > 0, debugWorkspaceSwitchStartTime > 0 else { return nil }
        return (debugWorkspaceSwitchId, debugWorkspaceSwitchStartTime)
    }

    private func debugPrimeWorkspaceSwitchTrigger(_ trigger: String, to target: UUID?) {
        guard selectedWorkspaceId != target else {
            debugPendingWorkspaceSwitchTrigger = nil
            debugPendingWorkspaceSwitchTarget = nil
            return
        }
        debugPendingWorkspaceSwitchTrigger = trigger
        debugPendingWorkspaceSwitchTarget = target
    }

    private func debugPrepareWorkspaceSwitch(_ trigger: String, from: UUID?, to: UUID?) {
        guard from != to else {
            debugPendingWorkspaceSwitchTrigger = nil
            debugPendingWorkspaceSwitchTarget = nil
            debugPreparedWorkspaceSwitchTarget = nil
            return
        }
        debugPendingWorkspaceSwitchTrigger = nil
        debugPendingWorkspaceSwitchTarget = nil
        debugBeginWorkspaceSwitch(trigger: trigger, from: from, to: to)
        debugPreparedWorkspaceSwitchTarget = to
    }

    private func debugBeginWorkspaceSwitch(trigger: String, from: UUID?, to: UUID?) {
        debugWorkspaceSwitchCounter &+= 1
        debugWorkspaceSwitchId = debugWorkspaceSwitchCounter
        debugWorkspaceSwitchStartTime = CACurrentMediaTime()
        dlog(
            "ws.switch.begin id=\(debugWorkspaceSwitchId) trigger=\(trigger) " +
            "from=\(Self.debugShortWorkspaceId(from)) to=\(Self.debugShortWorkspaceId(to)) " +
            "hot=\(isWorkspaceCycleHot ? 1 : 0) tabs=\(workspaces.count)"
        )
    }

    private static func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private static func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
#endif

    func selectWorkspace(at index: Int) {
        guard index >= 0 && index < workspaces.count else { return }
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("select_index", to: workspaces[index].id)
#endif
        selectedWorkspaceId = workspaces[index].id
    }

    func selectLastWorkspace() {
        guard let lastTab = workspaces.last else { return }
        selectedWorkspaceId = lastTab.id
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane of the selected workspace
    func selectNextSurface() {
        selectedWorkspace?.selectNextSurface()
    }

    /// Select the previous surface in the currently focused pane of the selected workspace
    func selectPreviousSurface() {
        selectedWorkspace?.selectPreviousSurface()
    }

    /// Select a surface by index in the currently focused pane of the selected workspace
    func selectSurface(at index: Int) {
        selectedWorkspace?.selectSurface(at: index)
    }

    /// Select the last surface in the currently focused pane of the selected workspace
    func selectLastSurface() {
        selectedWorkspace?.selectLastSurface()
    }

    /// Create a new terminal surface in the focused pane of the selected workspace.
    func newSurface() {
        // Cmd+T should always focus the newly created surface.
        selectedWorkspace?.clearSplitZoom()
        selectedWorkspace?.newTerminalSurfaceInFocusedPane(focus: true)
    }

    // MARK: - Split Creation

    /// Create a new split in the current tab
    @discardableResult
    func createSplit(direction: SplitDirection) -> UUID? {
        guard let selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceId }),
              let focusedPanelId = workspace.focusedPanelId else { return nil }
        return createSplit(workspaceId: selectedWorkspaceId, surfaceId: focusedPanelId, direction: direction)
    }

    /// Create a new split from an explicit source panel.
    @discardableResult
    func createSplit(workspaceId: UUID, surfaceId: UUID, direction: SplitDirection, focus: Bool = true) -> UUID? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }),
              workspace.panels[surfaceId] != nil else { return nil }
        workspace.clearSplitZoom()
        var splitCrumbData = surfaceShapeSummary(tabCount: workspaces.count)
        splitCrumbData["direction"] = String(describing: direction)
        sentryBreadcrumb("split.create", data: splitCrumbData)
        return newSplit(workspaceId: workspaceId, surfaceId: surfaceId, direction: direction, focus: focus)
    }

    /// Create a new browser split from the currently focused panel.
    @discardableResult
    func createBrowserSplit(direction: SplitDirection, url: URL? = nil) -> UUID? {
        guard let selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceId }),
              let focusedPanelId = workspace.focusedPanelId else { return nil }
        workspace.clearSplitZoom()
        return newBrowserSplit(
            workspaceId: selectedWorkspaceId,
            fromPanelId: focusedPanelId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            url: url
        )
    }

    /// Refresh Bonsplit right-side action button tooltips for all workspaces.
    func refreshSplitButtonTooltips() {
        for workspace in workspaces {
            workspace.refreshSplitButtonTooltips()
        }
    }

    // MARK: - Pane Focus Navigation

    /// Move focus to an adjacent pane in the specified direction
    func movePaneFocus(direction: NavigationDirection) {
        guard let selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedWorkspaceId }) else { return }
        workspace.moveFocus(direction: direction)
    }

    // MARK: - Recent Tab History Navigation

    private func recordWorkspaceInHistory(_ workspaceId: UUID) {
        // If we're not at the end of history, truncate forward history
        if historyIndex < workspaceHistory.count - 1 {
            workspaceHistory = Array(workspaceHistory.prefix(historyIndex + 1))
        }

        // Don't add duplicate consecutive entries
        if workspaceHistory.last == workspaceId {
            return
        }

        workspaceHistory.append(workspaceId)

        // Trim history if it exceeds max size
        if workspaceHistory.count > maxHistorySize {
            workspaceHistory.removeFirst(workspaceHistory.count - maxHistorySize)
        }

        historyIndex = workspaceHistory.count - 1
    }

    func navigateBack() {
        guard historyIndex > 0 else { return }

        // Find the previous valid tab in history (skip closed tabs)
        var targetIndex = historyIndex - 1
        while targetIndex >= 0 {
            let workspaceId = workspaceHistory[targetIndex]
            if workspaces.contains(where: { $0.id == workspaceId }) {
                isNavigatingHistory = true
                historyIndex = targetIndex
                selectedWorkspaceId = workspaceId
                isNavigatingHistory = false
                return
            }
            // Remove closed tab from history
            workspaceHistory.remove(at: targetIndex)
            historyIndex -= 1
            targetIndex -= 1
        }
    }

    func navigateForward() {
        guard historyIndex < workspaceHistory.count - 1 else { return }

        // Find the next valid tab in history (skip closed tabs)
        let targetIndex = historyIndex + 1
        while targetIndex < workspaceHistory.count {
            let workspaceId = workspaceHistory[targetIndex]
            if workspaces.contains(where: { $0.id == workspaceId }) {
                isNavigatingHistory = true
                historyIndex = targetIndex
                selectedWorkspaceId = workspaceId
                isNavigatingHistory = false
                return
            }
            // Remove closed tab from history
            workspaceHistory.remove(at: targetIndex)
            // Don't increment targetIndex since we removed the element
        }
    }

    var canNavigateBack: Bool {
        historyIndex > 0 && workspaceHistory.prefix(historyIndex).contains { workspaceId in
            workspaces.contains { $0.id == workspaceId }
        }
    }

    var canNavigateForward: Bool {
        historyIndex < workspaceHistory.count - 1 && workspaceHistory.suffix(from: historyIndex + 1).contains { workspaceId in
            workspaces.contains { $0.id == workspaceId }
        }
    }

    // MARK: - Split Operations (Backwards Compatibility)

    /// Create a new split in the specified direction
    /// Returns the new panel's ID (which is also the surface ID for terminals)
    func newSplit(workspaceId: UUID, surfaceId: UUID, direction: SplitDirection, focus: Bool = true, workingDirectory: String? = nil) -> UUID? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return nil }
        return workspace.newTerminalSplit(
            from: surfaceId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            focus: focus,
            workingDirectory: workingDirectory
        )?.id
    }

    /// Move focus in the specified direction
    func moveSplitFocus(workspaceId: UUID, surfaceId: UUID, direction: NavigationDirection) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return false }
        workspace.moveFocus(direction: direction)
        return true
    }

    /// Resize split - not directly supported by bonsplit, but we can adjust divider positions
    func resizeSplit(workspaceId: UUID, surfaceId: UUID, direction: ResizeDirection, amount: UInt16) -> Bool {
        // Bonsplit handles resize through its own divider dragging
        // This is a no-op for now as bonsplit manages divider positions internally
        return false
    }

    /// Equalize splits - not directly supported by bonsplit
    func equalizeSplits(workspaceId: UUID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return false }

        var foundSplit = false
        var allSucceeded = true
        equalizeSplits(
            in: workspace.bonsplitController.treeSnapshot(),
            controller: workspace.bonsplitController,
            foundSplit: &foundSplit,
            allSucceeded: &allSucceeded
        )
        return foundSplit && allSucceeded
    }

    /// Toggle zoom on a panel.
    func toggleSplitZoom(workspaceId: UUID, surfaceId: UUID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.toggleSplitZoom(panelId: surfaceId)
    }

    /// Toggle zoom for the currently focused panel in the selected workspace.
    @discardableResult
    func toggleFocusedSplitZoom() -> Bool {
        guard let workspace = selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId else { return false }
        return workspace.toggleSplitZoom(panelId: focusedPanelId)
    }

    private func equalizeSplits(
        in node: ExternalTreeNode,
        controller: BonsplitController,
        foundSplit: inout Bool,
        allSucceeded: inout Bool
    ) {
        switch node {
        case .pane:
            return
        case .split(let splitNode):
            foundSplit = true
            guard let splitId = UUID(uuidString: splitNode.id) else {
                allSucceeded = false
                return
            }

            if !controller.setDividerPosition(0.5, forSplit: splitId) {
                allSucceeded = false
            }

            equalizeSplits(
                in: splitNode.first,
                controller: controller,
                foundSplit: &foundSplit,
                allSucceeded: &allSucceeded
            )
            equalizeSplits(
                in: splitNode.second,
                controller: controller,
                foundSplit: &foundSplit,
                allSucceeded: &allSucceeded
            )
        }
    }

    /// Close a surface/panel
    func closeSurface(workspaceId: UUID, surfaceId: UUID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return false }
        // Guard against stale close callbacks (e.g. child-exit can trigger multiple actions).
        // A stale callback must never affect unrelated panels/workspaces.
        guard workspace.panels[surfaceId] != nil,
              workspace.bonsplitTabIdFromTabId(surfaceId) != nil else { return false }
        workspace.closeTab(surfaceId)
        AppDelegate.shared?.notificationStore?.clearNotifications(forWorkspaceId: workspaceId, surfaceId: surfaceId)
        return true
    }

    // MARK: - Browser Panel Operations

    /// Create a new browser panel in a split
    func newBrowserSplit(
        workspaceId: UUID,
        fromPanelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        focus: Bool = true
    ) -> UUID? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return nil }
        return workspace.newBrowserSplit(
            from: fromPanelId,
            orientation: orientation,
            insertFirst: insertFirst,
            url: url,
            preferredProfileID: preferredProfileID,
            focus: focus
        )?.id
    }

    /// Create a new browser surface in a pane
    func newBrowserSurface(
        workspaceId: UUID,
        inPane paneId: PaneID,
        url: URL? = nil,
        preferredProfileID: UUID? = nil
    ) -> UUID? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return nil }
        return workspace.newBrowserSurface(
            inPane: paneId,
            url: url,
            preferredProfileID: preferredProfileID
        )?.id
    }

    /// Get a browser panel by ID
    func browserPanel(workspaceId: UUID, panelId: UUID) -> BrowserTab? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return nil }
        return workspace.browserPanel(for: panelId)
    }

    /// Open a browser in a specific workspace, optionally preferring a split-right layout.
    @discardableResult
    func openBrowser(
        inWorkspace workspaceId: UUID,
        url: URL? = nil,
        preferSplitRight: Bool = false,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return nil }
        if selectedWorkspaceId != workspaceId {
            selectedWorkspaceId = workspaceId
        }

        if preferSplitRight {
            if let targetPaneId = workspace.topRightBrowserReusePane(),
               let browserTab = workspace.newBrowserSurface(
                   inPane: targetPaneId,
                   url: url,
                   focus: true,
                   insertAtEnd: insertAtEnd,
                   preferredProfileID: preferredProfileID
               ) {
                rememberFocusedSurface(workspaceId: workspaceId, surfaceId: browserTab.id)
                return browserTab.id
            }

            let splitSourcePanelId: UUID? = {
                if let focusedPanelId = workspace.focusedPanelId,
                   workspace.panels[focusedPanelId] != nil {
                    return focusedPanelId
                }
                if let rememberedPanelId = lastFocusedTabByWorkspace[workspaceId],
                   workspace.panels[rememberedPanelId] != nil {
                    return rememberedPanelId
                }
                if let orderedTabId = workspace.sidebarOrderedTabIds().first(where: { workspace.panels[$0] != nil }) {
                    return orderedTabId
                }
                return workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }.first
            }()

            if let splitSourcePanelId,
               let browserTab = workspace.newBrowserSplit(
                   from: splitSourcePanelId,
                   orientation: .horizontal,
                   url: url,
                   preferredProfileID: preferredProfileID,
                   focus: true
               ) {
                rememberFocusedSurface(workspaceId: workspaceId, surfaceId: browserTab.id)
                return browserTab.id
            }
        }

        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              let browserTab = workspace.newBrowserSurface(
                  inPane: paneId,
                  url: url,
                  focus: true,
                  insertAtEnd: insertAtEnd,
                  preferredProfileID: preferredProfileID
              ) else {
            return nil
        }
        rememberFocusedSurface(workspaceId: workspaceId, surfaceId: browserTab.id)
        return browserTab.id
    }

    /// Open a browser in the currently focused pane (as a new surface)
    @discardableResult
    func openBrowser(
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard let workspaceId = selectedWorkspaceId else { return nil }
        return openBrowser(
            inWorkspace: workspaceId,
            url: url,
            preferSplitRight: false,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        )
    }

    /// Reopen the most recently closed browser panel (Cmd+Shift+T).
    /// No-op when no browser panel restore snapshot is available.
    @discardableResult
    func reopenMostRecentlyClosedBrowserPanel() -> Bool {
        while let snapshot = recentlyClosedBrowsers.pop() {
            guard let targetWorkspace =
                workspaces.first(where: { $0.id == snapshot.workspaceId })
                ?? selectedWorkspace
                ?? workspaces.first else {
                return false
            }
            let preReopenFocusedPanelId = focusedPanelId(for: targetWorkspace.id)

            if selectedWorkspaceId != targetWorkspace.id {
                selectedWorkspaceId = targetWorkspace.id
            }

            if let reopenedPanelId = reopenClosedBrowserTab(snapshot, in: targetWorkspace) {
                enforceReopenedBrowserFocus(
                    workspaceId: targetWorkspace.id,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
                return true
            }
        }

        return false
    }

    private func enforceReopenedBrowserFocus(
        workspaceId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        // Keep workspace-switch restoration pinned to the reopened browser panel.
        rememberFocusedSurface(workspaceId: workspaceId, surfaceId: reopenedPanelId)
        enforceReopenedBrowserFocusIfNeeded(
            workspaceId: workspaceId,
            reopenedPanelId: reopenedPanelId,
            preReopenFocusedPanelId: preReopenFocusedPanelId
        )

        // Some stale focus callbacks can land one runloop turn later. Re-assert focus in two
        // consecutive turns, but only when focus drifted back to the pre-reopen panel.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enforceReopenedBrowserFocusIfNeeded(
                workspaceId: workspaceId,
                reopenedPanelId: reopenedPanelId,
                preReopenFocusedPanelId: preReopenFocusedPanelId
            )
            DispatchQueue.main.async { [weak self] in
                self?.enforceReopenedBrowserFocusIfNeeded(
                    workspaceId: workspaceId,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
            }
        }
    }

    private func enforceReopenedBrowserFocusIfNeeded(
        workspaceId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        guard selectedWorkspaceId == workspaceId,
              let workspace = workspaces.first(where: { $0.id == workspaceId }),
              workspace.panels[reopenedPanelId] != nil else {
            return
        }

        rememberFocusedSurface(workspaceId: workspaceId, surfaceId: reopenedPanelId)

        guard workspace.focusedPanelId != reopenedPanelId else { return }

        if let focusedPanelId = workspace.focusedPanelId,
           let preReopenFocusedPanelId,
           focusedPanelId != preReopenFocusedPanelId {
            return
        }

        workspace.focusPanel(reopenedPanelId)
    }

    private func reopenClosedBrowserTab(
        _ snapshot: ClosedBrowserTabRestoreSnapshot,
        in workspace: Workspace
    ) -> UUID? {
        if let originalPane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == snapshot.originalPaneId }),
           let browserTab = workspace.newBrowserSurface(
               inPane: originalPane,
               url: snapshot.url,
               focus: true,
               preferredProfileID: snapshot.profileID
           ) {
            let bonsplitTabCount = workspace.bonsplitController.tabs(inPane: originalPane).count
            let maxIndex = max(0, bonsplitTabCount - 1)
            let targetIndex = min(max(snapshot.originalTabIndex, 0), maxIndex)
            _ = workspace.reorderSurface(panelId: browserTab.id, toIndex: targetIndex)
            return browserTab.id
        }

        if let orientation = snapshot.fallbackSplitOrientation,
           let fallbackAnchorPaneId = snapshot.fallbackAnchorPaneId,
           let anchorPane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == fallbackAnchorPaneId }),
           let anchorBonsplitTab = workspace.bonsplitController.selectedTab(inPane: anchorPane) ?? workspace.bonsplitController.tabs(inPane: anchorPane).first,
           let anchorTabId = workspace.tabIdFromBonsplitTabId(anchorBonsplitTab.id),
           let browserPanelId = workspace.newBrowserSplit(
               from: anchorTabId,
               orientation: orientation,
               insertFirst: snapshot.fallbackSplitInsertFirst,
               url: snapshot.url,
               preferredProfileID: snapshot.profileID
           )?.id {
            return browserPanelId
        }

        guard let focusedPane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }
        return workspace.newBrowserSurface(
            inPane: focusedPane,
            url: snapshot.url,
            focus: true,
            preferredProfileID: snapshot.profileID
        )?.id
    }

    /// Flash the currently focused panel so the user can visually confirm focus.
    func triggerFocusFlash() {
        guard let workspace = selectedWorkspace,
              let panelId = workspace.focusedPanelId else { return }
        workspace.triggerFocusFlash(panelId: panelId)
    }

    /// Ensure AppKit first responder matches the currently focused terminal panel.
    /// This keeps real keyboard events (including Ctrl+D) on the same panel as the
    /// bonsplit focus indicator after rapid split topology changes.
    func ensureFocusedTerminalFirstResponder() {
        guard let workspace = selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminal = workspace.terminalPanel(for: panelId) else { return }
        terminal.hostedView.ensureFocus(for: workspace.id, surfaceId: panelId)
    }

    /// Reconcile keyboard routing before terminal control shortcuts (e.g. Ctrl+D).
    ///
    /// Source of truth for pane focus is bonsplit's focused pane + selected tab.
    /// Keyboard delivery must converge AppKit first responder to that model state, not mutate
    /// the model from whatever first responder happened to be during reparenting transitions.
    func reconcileFocusedPanelFromFirstResponderForKeyboard() {
        ensureFocusedTerminalFirstResponder()
    }

    /// Get a terminal panel by ID
    func terminalPanel(workspaceId: UUID, panelId: UUID) -> TerminalTab? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return nil }
        return workspace.terminalPanel(for: panelId)
    }

    /// Get the panel for a surface ID (terminal panels use surface ID as panel ID)
    func surface(for workspaceId: UUID, surfaceId: UUID) -> TerminalSurface? {
        terminalPanel(workspaceId: workspaceId, panelId: surfaceId)?.surface
    }

#if DEBUG
    @MainActor
    private func waitForWorkspacePanelsCondition(
        workspace: Workspace,
        timeoutSeconds: TimeInterval,
        condition: @escaping (Workspace) -> Bool
    ) async -> Bool {
        guard !condition(workspace) else { return true }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resolved = false
            var cancellable: AnyCancellable?

            func finish(_ value: Bool) {
                guard !resolved else { return }
                resolved = true
                cancellable?.cancel()
                cont.resume(returning: value)
            }

            func evaluate() {
                if condition(workspace) {
                    finish(true)
                }
            }

            cancellable = workspace.$panels
                .map { _ in () }
                .sink { _ in evaluate() }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                Task { @MainActor in
                    finish(condition(workspace))
                }
            }
            evaluate()
        }
    }

    @MainActor
    private func waitForTerminalTabCondition(
        workspace: Workspace,
        panelId: UUID,
        timeoutSeconds: TimeInterval,
        condition: @escaping (TerminalTab) -> Bool
    ) async -> Bool {
        if let panel = workspace.terminalPanel(for: panelId), condition(panel) {
            return true
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resolved = false
            var panelsCancellable: AnyCancellable?
            var readyObserver: NSObjectProtocol?
            var hostedViewObserver: NSObjectProtocol?

            @MainActor
            func finish(_ value: Bool) {
                guard !resolved else { return }
                resolved = true
                panelsCancellable?.cancel()
                if let readyObserver {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if let hostedViewObserver {
                    NotificationCenter.default.removeObserver(hostedViewObserver)
                }
                cont.resume(returning: value)
            }

            @MainActor
            func evaluate() {
                guard let panel = workspace.terminalPanel(for: panelId) else {
                    finish(false)
                    return
                }
                panel.surface.requestBackgroundSurfaceStartIfNeeded()
                if condition(panel) {
                    finish(true)
                }
            }

            panelsCancellable = workspace.$panels
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in
                        evaluate()
                    }
                }
            readyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { note in
                guard let readySurfaceId = note.userInfo?["surfaceId"] as? UUID,
                      readySurfaceId == panelId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }
            hostedViewObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceHostedViewDidMoveToWindow,
                object: nil,
                queue: .main
            ) { note in
                guard let hostedSurfaceId = note.userInfo?["surfaceId"] as? UUID,
                      hostedSurfaceId == panelId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                Task { @MainActor in
                    if let panel = workspace.terminalPanel(for: panelId) {
                        finish(condition(panel))
                    } else {
                        finish(false)
                    }
                }
            }
            evaluate()
        }
    }

    @MainActor
    private func waitForTerminalPanelReadyForUITest(
        workspace: Workspace,
        panelId: UUID,
        timeoutSeconds: TimeInterval = 6.0
    ) async -> (attached: Bool, hasSurface: Bool, firstResponder: Bool) {
        var attached = false
        var hasSurface = false
        var firstResponder = false

        let _ = await waitForTerminalTabCondition(
            workspace: workspace,
            panelId: panelId,
            timeoutSeconds: timeoutSeconds
        ) { panel in
            panel.surface.requestBackgroundSurfaceStartIfNeeded()
            attached = panel.surface.isViewInWindow
            hasSurface = panel.surface.surface != nil
            firstResponder = panel.hostedView.isSurfaceViewFirstResponder()
            return attached && hasSurface
        }

        return (attached, hasSurface, firstResponder)
    }

    private func setupUITestFocusShortcutsIfNeeded() {
        guard !didSetupUITestFocusShortcuts else { return }
        didSetupUITestFocusShortcuts = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_FOCUS_SHORTCUTS"] == "1" else { return }

        // UI tests can't record arrow keys via the shortcut recorder. Use letter-based shortcuts
        // so tests can reliably drive pane navigation without mouse clicks.
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "h", command: true, shift: false, option: false, control: true),
            for: .focusLeft
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "l", command: true, shift: false, option: false, control: true),
            for: .focusRight
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: false, option: false, control: true),
            for: .focusUp
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "j", command: true, shift: false, option: false, control: true),
            for: .focusDown
        )
    }

    private func setupSplitCloseRightUITestIfNeeded() {
        guard !didSetupSplitCloseRightUITest else { return }
        didSetupSplitCloseRightUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"], !path.isEmpty else { return }
        let visualMode = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == "1"
        let shotsDir = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SHOTS_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let visualIterations = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] ?? "20").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 20
        let burstFrames = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] ?? "6").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 6
        let closeDelayMs = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] ?? "70").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 70
        let pattern = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] ?? "close_right")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let workspace = self.selectedWorkspace else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing selected workspace"], at: path)
                    return
                }

                guard let topLeftPanelId = workspace.focusedPanelId else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing initial focused panel"], at: path)
                    return
                }
                let initialTerminalReadiness = await self.waitForTerminalPanelReadyForUITest(
                    workspace: workspace,
                    panelId: topLeftPanelId
                )

                guard initialTerminalReadiness.attached,
                      initialTerminalReadiness.hasSurface,
                      let terminal = workspace.terminalPanel(for: topLeftPanelId) else {
                    self.writeSplitCloseRightTestData([
                        "preTerminalAttached": initialTerminalReadiness.attached ? "1" : "0",
                        "preTerminalSurfaceNil": initialTerminalReadiness.hasSurface ? "0" : "1",
                        "setupError": "Initial terminal not ready (not attached or surface nil)"
                    ], at: path)
                    return
                }

                self.writeSplitCloseRightTestData([
                    "preTerminalAttached": "1",
                    "preTerminalSurfaceNil": terminal.surface.surface == nil ? "1" : "0"
                ], at: path)

                if visualMode {
                    // Visual repro mode: repeat the split/close sequence many times and write
                    // screenshots to `shotsDir`. This avoids relying on XCUITest to click hover-only
                    // close buttons, while still exercising the "close unfocused right tabs" path.
                    self.writeSplitCloseRightTestData([
                        "visualMode": "1",
                        "visualIterations": String(visualIterations),
                        "visualDone": "0"
                    ], at: path)

                    await self.runSplitCloseRightVisualRepro(
                        workspace: workspace,
                        topLeftPanelId: topLeftPanelId,
                        path: path,
                        shotsDir: shotsDir,
                        iterations: max(1, min(visualIterations, 60)),
                        burstFrames: max(0, min(burstFrames, 80)),
                        closeDelayMs: max(0, min(closeDelayMs, 500)),
                        pattern: pattern
                    )

                    self.writeSplitCloseRightTestData(["visualDone": "1"], at: path)
                    return
                }

                // Layout goal: 2x2 grid (2 top, 2 bottom), then close both right panels.
                // Order matters: split down first, then split right in each row (matches UI shortcut repro).
                guard let bottomLeft = workspace.newTerminalSplit(from: topLeftPanelId, orientation: .vertical) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-left split"], at: path)
                    return
                }
                guard let bottomRight = workspace.newTerminalSplit(from: bottomLeft.id, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-right split"], at: path)
                    return
                }
                workspace.focusPanel(topLeftPanelId)
                guard let topRight = workspace.newTerminalSplit(from: topLeftPanelId, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create top-right split"], at: path)
                    return
                }

                self.writeSplitCloseRightTestData([
                    "tabId": workspace.id.uuidString,
                    "topLeftTabId": topLeftPanelId.uuidString,
                    "bottomLeftTabId": bottomLeft.id.uuidString,
                    "topRightTabId": topRight.id.uuidString,
                    "bottomRightTabId": bottomRight.id.uuidString,
                    "createdAreaCount": String(workspace.bonsplitController.allPaneIds.count),
                    "createdTabCount": String(workspace.panels.count)
                ], at: path)

                DebugUIEventCounters.resetEmptyPanelAppearCount()

                // Close the two right panes via the same path as Cmd+W.
                workspace.focusPanel(topRight.id)
                workspace.closeTab(topRight.id, force: true)
                workspace.focusPanel(bottomRight.id)
                workspace.closeTab(bottomRight.id, force: true)


                // Capture final state after Bonsplit/AppKit/Ghostty geometry reconciliation.
                // We avoid sleep-based timing and converge over a few main-actor turns.
                 @MainActor func collectSplitCloseRightState() -> (data: [String: String], settled: Bool) {
                    let paneIds = workspace.bonsplitController.allPaneIds
                    let bonsplitTabCount = workspace.bonsplitController.allTabIds.count
                    let panelCount = workspace.panels.count

                    var missingSelectedTabCount = 0
                    var missingPanelMappingCount = 0
                    var selectedTerminalCount = 0
                    var selectedTerminalAttachedCount = 0
                    var selectedTerminalZeroSizeCount = 0
                    var selectedTerminalSurfaceNilCount = 0

                    for paneId in paneIds {
                        guard let selected = workspace.bonsplitController.selectedTab(inPane: paneId) else {
                            missingSelectedTabCount += 1
                            continue
                        }
                        guard let panel = workspace.panel(for: selected.id) else {
                            missingPanelMappingCount += 1
                            continue
                        }
                        if let terminal = panel as? TerminalTab {
                            selectedTerminalCount += 1
                            if terminal.surface.isViewInWindow {
                                selectedTerminalAttachedCount += 1
                            }
                            let size = terminal.hostedView.bounds.size
                            if size.width < 5 || size.height < 5 {
                                selectedTerminalZeroSizeCount += 1
                            }
                            if terminal.surface.surface == nil {
                                selectedTerminalSurfaceNilCount += 1
                            }
                        }
                    }

                    let settled =
                        paneIds.count == 2 &&
                        missingSelectedTabCount == 0 &&
                        missingPanelMappingCount == 0 &&
                        DebugUIEventCounters.emptyPanelAppearCount == 0 &&
                        selectedTerminalCount == 2 &&
                        selectedTerminalAttachedCount == 2 &&
                        selectedTerminalZeroSizeCount == 0 &&
                        selectedTerminalSurfaceNilCount == 0

                    return (
                        data: [
                            "finalAreaCount": String(paneIds.count),
                            "finalBonsplitTabCount": String(bonsplitTabCount),
                            "finalTabCount": String(panelCount),
                            "missingSelectedTabCount": String(missingSelectedTabCount),
                            "missingTabMappingCount": String(missingPanelMappingCount),
                            "emptyTabAppearCount": String(DebugUIEventCounters.emptyPanelAppearCount),
                            "selectedTerminalCount": String(selectedTerminalCount),
                            "selectedTerminalAttachedCount": String(selectedTerminalAttachedCount),
                            "selectedTerminalZeroSizeCount": String(selectedTerminalZeroSizeCount),
                            "selectedTerminalSurfaceNilCount": String(selectedTerminalSurfaceNilCount),
                        ],
                        settled: settled
                    )
                }
                 @MainActor func reconcileVisibleTerminalGeometry() {
                    NSApp.windows.forEach { window in
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.contentView?.displayIfNeeded()
                    }
                    for paneId in workspace.bonsplitController.allPaneIds {
                        guard let selected = workspace.bonsplitController.selectedTab(inPane: paneId),
                              let terminal = workspace.panel(for: selected.id) as? TerminalTab else {
                            continue
                        }
                        terminal.hostedView.reconcileGeometryNow()
                        terminal.surface.forceRefresh()
                    }
                }

                var finalState = collectSplitCloseRightState()
                for attempt in 1...8 {
                    reconcileVisibleTerminalGeometry()
                    await Task.yield()
                    finalState = collectSplitCloseRightState()
                    var payload = finalState.data
                    payload["finalAttempt"] = String(attempt)
                    self.writeSplitCloseRightTestData(payload, at: path)
                    if finalState.settled {
                        break
                    }
                }
            }
        }
    }

	    @MainActor
	    private func runSplitCloseRightVisualRepro(
	        workspace: Workspace,
	        topLeftPanelId: UUID,
	        path: String,
	        shotsDir: String,
	        iterations: Int,
	        burstFrames: Int,
	        closeDelayMs: Int,
	        pattern: String
	    ) async {
        _ = shotsDir // legacy: screenshots removed in favor of IOSurface sampling

        func sendText(_ panelId: UUID, _ text: String) {
            guard let tp = workspace.terminalPanel(for: panelId) else { return }
            tp.surface.sendText(text)
        }

        // Sample a very top strip so the probe remains valid even after vertical expand/collapse.
        // We pin marker text to row 1 before each close sequence.
        let sampleCrop = CGRect(x: 0.04, y: 0.01, width: 0.92, height: 0.08)

        for i in 1...iterations {
            // Reset to a single pane: close everything except the top-left panel.
            workspace.focusPanel(topLeftPanelId)
            let toClose = Array(workspace.panels.keys).filter { $0 != topLeftPanelId }
            for pid in toClose {
                workspace.closeTab(pid, force: true)
            }

            // Create the repro layout. Most patterns use a 2x2 grid, but keep a single-split
            // variant for the exact "close right in a horizontal pair" user report.
            let topLeftId = topLeftPanelId
            let topRight: TerminalTab
            var bottomLeft: TerminalTab?
            var bottomRight: TerminalTab?

            switch pattern {
            case "close_right_single":
                guard let tr = workspace.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
            case "close_right_lrtd", "close_right_lrtd_bottom_first", "close_right_bottom_first", "close_right_lrtd_unfocused":
                // User repro: split left/right first, then split top/down in each column.
                guard let tr = workspace.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let bl = workspace.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from left (iteration \(i))"], at: path)
                    return
                }
                guard let br = workspace.newTerminalSplit(from: tr.id, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from right (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            default:
                // Default: split top/down first, then split left/right in each row.
                guard let bl = workspace.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let br = workspace.newTerminalSplit(from: bl.id, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from bottom-left (iteration \(i))"], at: path)
                    return
                }
                guard let tr = workspace.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            }

            // Let newly created surfaces attach before priming content, so sampled panes have
            // stable non-blank text before the close timeline begins.
            try? await Task.sleep(nanoseconds: 180_000_000)

            // Fill left panes with visible content.
            sendText(topLeftId, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_TOPLEFT_\(i); done; printf '\\033[HCMUX_MARKER_TOPLEFT\\n'\r")
            sendText(topRight.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_TOPRIGHT_\(i); done; printf '\\033[HCMUX_MARKER_TOPRIGHT\\n'\r")
            if let bottomLeft {
                sendText(bottomLeft.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_BOTTOMLEFT_\(i); done; printf '\\033[HCMUX_MARKER_BOTTOMLEFT\\n'\r")
            }
            if let bottomRight {
                sendText(bottomRight.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_BOTTOMRIGHT_\(i); done; printf '\\033[HCMUX_MARKER_BOTTOMRIGHT\\n'\r")
            }
            // Give shell output a moment to paint before we start the close timeline.
            try? await Task.sleep(nanoseconds: 180_000_000)

            let desiredFrames = max(16, min(burstFrames, 60))
            let closeFrame = min(6, max(1, desiredFrames / 4))
            let delayFrames = max(0, Int((Double(max(0, closeDelayMs)) / 16.6667).rounded(.up)))
            let secondCloseFrame = min(desiredFrames - 1, closeFrame + delayFrames)

            var closeOrder = ""
            let actions: [(frame: Int, action: () -> Void)] = {
                switch pattern {
                case "close_right_single":
                    closeOrder = "TR_ONLY"
                    return [
                        (frame: closeFrame, action: {
                            workspace.focusPanel(topRight.id)
                            workspace.closeTab(topRight.id, force: true)
                        }),
                    ]
                case "close_bottom":
                    guard let bottomRight, let bottomLeft else { return [] }
                    closeOrder = "BR_THEN_BL"
                    return [
                        (frame: closeFrame, action: {
                            workspace.focusPanel(bottomRight.id)
                            workspace.closeTab(bottomRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            workspace.focusPanel(bottomLeft.id)
                            workspace.closeTab(bottomLeft.id, force: true)
                        }),
                    ]
                case "close_right_lrtd_bottom_first", "close_right_bottom_first":
                    guard let bottomRight else { return [] }
                    closeOrder = "BR_THEN_TR"
                    return [
                        (frame: closeFrame, action: {
                            workspace.focusPanel(bottomRight.id)
                            workspace.closeTab(bottomRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            workspace.focusPanel(topRight.id)
                            workspace.closeTab(topRight.id, force: true)
                        }),
                    ]
                case "close_right_lrtd_unfocused":
                    guard let bottomRight else { return [] }
                    closeOrder = "TR_THEN_BR_UNFOCUSED"
                    return [
                        (frame: closeFrame, action: {
                            workspace.closeTab(topRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            workspace.closeTab(bottomRight.id, force: true)
                        }),
                    ]
                default:
                    guard let bottomRight else { return [] }
                    closeOrder = "TR_THEN_BR"
                    return [
                        (frame: closeFrame, action: {
                            workspace.focusPanel(topRight.id)
                            workspace.closeTab(topRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            workspace.focusPanel(bottomRight.id)
                            workspace.closeTab(bottomRight.id, force: true)
                        }),
                    ]
                }
            }()

            let targets: [(label: String, view: GhosttySurfaceScrollView)] = {
                switch pattern {
                case "close_right_single":
                    return [
                        ("TL", workspace.terminalPanel(for: topLeftId)!.surface.hostedView),
                    ]
                case "close_bottom":
                    return [
                        ("TL", workspace.terminalPanel(for: topLeftId)!.surface.hostedView),
                        ("TR", topRight.surface.hostedView),
                    ]
                case "close_right_lrtd_bottom_first", "close_right_bottom_first":
                    return [
                        ("TR", topRight.surface.hostedView),
                        ("TL", workspace.terminalPanel(for: topLeftId)!.surface.hostedView),
                    ]
                default:
                    guard let bottomLeft else { return [] }
                    return [
                        ("TL", workspace.terminalPanel(for: topLeftId)!.surface.hostedView),
                        ("BL", bottomLeft.surface.hostedView),
                    ]
                }
            }()

            let result = await captureVsyncIOSurfaceTimeline(
                frameCount: desiredFrames,
                closeFrame: closeFrame,
                crop: sampleCrop,
                targets: targets,
                actions: actions
            )

            let paneStateTrace: String = {
                workspace.bonsplitController.allPaneIds.map { paneId in
                    let bonsplitTabs = workspace.bonsplitController.tabs(inPane: paneId)
                    let selected = workspace.bonsplitController.selectedTab(inPane: paneId)
                    let selectedId = selected.map { String(describing: $0.id) } ?? "nil"
                    let selectedTabId = selected.flatMap { workspace.tabIdFromBonsplitTabId($0.id) }
                    let selectedPanelLive: String = {
                        guard let selected else { return "0" }
                        return workspace.panel(for: selected.id) != nil ? "1" : "0"
                    }()
                    let mappedCount = bonsplitTabs.filter { workspace.tabIdFromBonsplitTabId($0.id) != nil }.count
                    let selectedPanel = selectedTabId?.uuidString.prefix(8) ?? "nil"
                    return "pane=\(paneId.id.uuidString.prefix(8)):tabs=\(bonsplitTabs.count):mapped=\(mappedCount):selected=\(selectedId.prefix(8)):selectedPanel=\(selectedPanel):selectedLive=\(selectedPanelLive)"
                }.joined(separator: ";")
            }()

            writeSplitCloseRightTestData([
                "pattern": pattern,
                "iteration": String(i),
                "closeDelayMs": String(closeDelayMs),
                "closeDelayFrames": String(delayFrames),
                "closeOrder": closeOrder,
                "timelineFrameCount": String(desiredFrames),
                "timelineCloseFrame": String(closeFrame),
                "timelineSecondCloseFrame": String(secondCloseFrame),
                "timelineFirstBlank": result.firstBlank.map { "\($0.label)@\($0.frame)" } ?? "",
                "timelineFirstSizeMismatch": result.firstSizeMismatch.map { "\($0.label)@\($0.frame):ios=\($0.ios):exp=\($0.expected)" } ?? "",
                "timelineTrace": result.trace.joined(separator: "|"),
                "timelineAreaState": paneStateTrace,
                "visualLastIteration": String(i),
            ], at: path)

            if let firstBlank = result.firstBlank {
                writeSplitCloseRightTestData([
                    "blankFrameSeen": "1",
                    "blankObservedIteration": String(i),
                    "blankObservedAt": "\(firstBlank.label)@\(firstBlank.frame)"
                ], at: path)
                return
            }

            if let firstMismatch = result.firstSizeMismatch {
                writeSplitCloseRightTestData([
                    "sizeMismatchSeen": "1",
                    "sizeMismatchObservedIteration": String(i),
                    "sizeMismatchObservedAt": "\(firstMismatch.label)@\(firstMismatch.frame):ios=\(firstMismatch.ios):exp=\(firstMismatch.expected)"
                ], at: path)
                return
            }
        }
	    }

	    @MainActor
	    private func captureVsyncIOSurfaceTimeline(
	        frameCount: Int,
	        closeFrame: Int,
	        crop: CGRect,
	        targets: [(label: String, view: GhosttySurfaceScrollView)],
	        actions: [(frame: Int, action: () -> Void)] = []
	    ) async -> (firstBlank: (label: String, frame: Int)?, firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?, trace: [String]) {
	        guard frameCount > 0 else { return (nil, nil, []) }

	        let st = VsyncIOSurfaceTimelineState(frameCount: frameCount, closeFrame: closeFrame)
	        st.scheduledActions = actions.sorted(by: { $0.frame < $1.frame })
	        st.nextActionIndex = 0
	        st.targets = targets.map { t in
	            VsyncIOSurfaceTimelineState.Target(label: t.label, sample: { @MainActor in
	                t.view.debugSampleIOSurface(normalizedCrop: crop)
	            })
	        }

	        let unmanaged = Unmanaged.passRetained(st)
	        let ctx = unmanaged.toOpaque()

	        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
	            st.continuation = cont
	            var link: CVDisplayLink?
	            CVDisplayLinkCreateWithActiveCGDisplays(&link)
	            guard let link else {
	                st.finish()
	                Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
	                return
	            }
	            st.link = link

	            CVDisplayLinkSetOutputCallback(link, cmuxVsyncIOSurfaceTimelineCallback, ctx)
	            CVDisplayLinkStart(link)
	        }

	        return (st.firstBlank, st.firstSizeMismatch, st.trace)
	    }

    private func writeSplitCloseRightTestData(_ updates: [String: String], at path: String) {
        var payload = loadSplitCloseRightTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadSplitCloseRightTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func setupChildExitSplitUITestIfNeeded() {
        guard !didSetupChildExitSplitUITest else { return }
        didSetupChildExitSplitUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_PATH"], !path.isEmpty else { return }
        let requestedIterations = Int(env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_ITERATIONS"] ?? "1") ?? 1
        let iterations = max(1, min(requestedIterations, 20))

        func write(_ updates: [String: String]) {
            var payload: [String: String] = {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return [:]
                }
                return obj
            }()
            for (k, v) in updates { payload[k] = v }
            guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Small delay so the initial window/panel has completed first layout.
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let ws = self.selectedWorkspace else {
                write(["setupError": "Missing selected workspace", "done": "1"])
                return
            }
            write([
                "requestedIterations": String(requestedIterations),
                "iterations": String(iterations),
                "workspaceCountBefore": String(self.workspaces.count),
                "panelCountBefore": String(ws.panels.count),
                "done": "0",
            ])

            var completedIterations = 0
            var timedOut = false
            var closedWorkspace = false

            for i in 1...iterations {
                guard self.workspaces.contains(where: { $0.id == ws.id }) else {
                    closedWorkspace = true
                    break
                }

                guard let leftPanelId = ws.focusedPanelId ?? ws.panels.keys.first else {
                    write(["setupError": "Missing focused panel before iteration \(i)", "done": "1"])
                    return
                }

                // Start each iteration from a deterministic 1x1 workspace.
                if ws.panels.count > 1 {
                    for panelId in ws.panels.keys where panelId != leftPanelId {
                        ws.closeTab(panelId, force: true)
                    }
                    let collapsed = await self.waitForWorkspacePanelsCondition(
                        workspace: ws,
                        timeoutSeconds: 2.0
                    ) { workspace in
                        workspace.panels.count == 1
                    }
                    if !collapsed {
                        write(["setupError": "Timed out collapsing workspace before iteration \(i)", "done": "1"])
                        return
                    }
                }

                guard let rightPanel = ws.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                    write(["setupError": "Failed to create right split at iteration \(i)", "done": "1"])
                    return
                }

                write([
                    "iteration": String(i),
                    "leftTabId": leftPanelId.uuidString,
                    "rightTabId": rightPanel.id.uuidString,
                ])

                ws.focusPanel(rightPanel.id)
                // Wait for the split terminal surface to be attached before sending exit.
                // Without this, very early writes can be dropped during initial surface creation.
                _ = await self.waitForTerminalTabCondition(
                    workspace: ws,
                    panelId: rightPanel.id,
                    timeoutSeconds: 2.0
                ) { panel in
                    panel.surface.isViewInWindow && panel.surface.surface != nil
                }
                // Use an explicit shell exit command for deterministic child-exit behavior across
                // startup timing variance; this still exercises the same SHOW_CHILD_EXITED path.
                rightPanel.surface.sendText("exit\r")

                // Wait for the right panel to close.
                let closed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    var cancellable: AnyCancellable?
                    var resolved = false

                    func finish(_ value: Bool) {
                        guard !resolved else { return }
                        resolved = true
                        cancellable?.cancel()
                        cont.resume(returning: value)
                    }

                    cancellable = ws.$panels
                        .map { $0.count }
                        .removeDuplicates()
                        .sink { count in
                            if count == 1 {
                                finish(true)
                            }
                        }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                        finish(false)
                    }
                }

                if !closed {
                    timedOut = true
                    write(["timedOutIteration": String(i)])
                    break
                }

                if !self.workspaces.contains(where: { $0.id == ws.id }) {
                    closedWorkspace = true
                    write(["closedWorkspaceIteration": String(i)])
                    break
                }

                completedIterations = i
            }

            let workspaceStillOpen = self.workspaces.contains(where: { $0.id == ws.id })
            let effectiveClosedWorkspace = closedWorkspace || !workspaceStillOpen

            write([
                "workspaceCountAfter": String(self.workspaces.count),
                "tabCountAfter": String(ws.panels.count),
                "workspaceStillOpen": workspaceStillOpen ? "1" : "0",
                "closedWorkspace": effectiveClosedWorkspace ? "1" : "0",
                "timedOut": timedOut ? "1" : "0",
                "completedIterations": String(completedIterations),
                "done": "1",
            ])
        }
    }

    private func setupChildExitKeyboardUITestIfNeeded() {
        guard !didSetupChildExitKeyboardUITest else { return }
        didSetupChildExitKeyboardUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"], !path.isEmpty else { return }
        let autoTrigger = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] == "1"
        let strictKeyOnly = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT"] == "1"
        let triggerMode = (env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_TRIGGER_MODE"] ?? "shell_input")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let useEarlyCtrlShiftTrigger = triggerMode == "early_ctrl_shift_d"
        let useEarlyCtrlDTrigger = triggerMode == "early_ctrl_d"
        let useEarlyTrigger = useEarlyCtrlShiftTrigger || useEarlyCtrlDTrigger
        let triggerUsesShift = triggerMode == "ctrl_shift_d" || useEarlyCtrlShiftTrigger
        let layout = (env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] ?? "lr")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedPanelsAfter = max(
            1,
            Int((env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] ?? "1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? 1
        )

        func write(_ updates: [String: String]) {
            var payload: [String: String] = {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return [:]
                }
                return obj
            }()
            for (k, v) in updates { payload[k] = v }
            guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let ws = self.selectedWorkspace else {
                write(["setupError": "Missing selected workspace", "done": "1"])
                return
            }
            guard let leftPanelId = ws.focusedPanelId else {
                write(["setupError": "Missing initial focused panel", "done": "1"])
                return
            }
            guard let rightPanel = ws.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                write(["setupError": "Failed to create right split", "done": "1"])
                return
            }

            var bottomLeftPanelId = ""
            let topRightPanelId = rightPanel.id.uuidString
            var bottomRightPanelId = ""
            var exitPanelId = rightPanel.id

            if layout == "lr_left_vertical" {
                guard let bottomLeft = ws.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
            } else if layout == "lrtd_close_right_then_exit_top_left" {
                guard let bottomLeft = ws.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                guard let bottomRight = ws.newTerminalSplit(from: rightPanel.id, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-right split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
                bottomRightPanelId = bottomRight.id.uuidString

                // Repro flow: with a 2x2 (left/right then top/down), close both right panes,
                // then trigger Ctrl+D in top-left.
                ws.focusPanel(rightPanel.id)
                ws.closeTab(rightPanel.id, force: true)
                ws.focusPanel(bottomRight.id)
                ws.closeTab(bottomRight.id, force: true)
                exitPanelId = leftPanelId

                let collapsed = await self.waitForWorkspacePanelsCondition(
                    workspace: ws,
                    timeoutSeconds: 2.0
                ) { workspace in
                    workspace.panels.count == 2
                }
                if !collapsed {
                    write([
                        "setupError": "Expected 2 panels after closing right column, got \(ws.panels.count)",
                        "done": "1",
                    ])
                    return
                }
            } else if layout == "tdlr_close_bottom_then_exit_top_left" {
                // Alternate repro flow:
                // 1) split top/down
                // 2) split left/right for each row (2x2)
                // 3) close both bottom panes
                // 4) trigger Ctrl+D in top-left
                guard let bottomLeft = ws.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                guard let topRight = ws.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                    write(["setupError": "Failed to create top-right split", "done": "1"])
                    return
                }
                guard let bottomRight = ws.newTerminalSplit(from: bottomLeft.id, orientation: .horizontal) else {
                    write(["setupError": "Failed to create bottom-right split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
                bottomRightPanelId = bottomRight.id.uuidString

                // Close every pane except the top row; do it one-by-one and wait for model convergence.
                let keepPanels: Set<UUID> = [leftPanelId, topRight.id]
                for panelId in Array(ws.panels.keys) where !keepPanels.contains(panelId) {
                    ws.focusPanel(panelId)
                    ws.closeTab(panelId, force: true)
                    let closed = await self.waitForWorkspacePanelsCondition(
                        workspace: ws,
                        timeoutSeconds: 1.0
                    ) { workspace in
                        workspace.panels[panelId] == nil
                    }
                    if !closed {
                        write([
                            "setupError": "Failed to close bottom pane \(panelId.uuidString)",
                            "done": "1",
                        ])
                        return
                    }
                }
                exitPanelId = leftPanelId

                let collapsed = await self.waitForWorkspacePanelsCondition(
                    workspace: ws,
                    timeoutSeconds: 2.0
                ) { workspace in
                    workspace.panels.count == 2
                }
                if !collapsed {
                    write([
                        "setupError": "Expected 2 panels after closing bottom row, got \(ws.panels.count)",
                        "done": "1",
                    ])
                    return
                }
            }

            ws.focusPanel(exitPanelId)
            // Keep child-exit keyboard tests deterministic across user shell configs.
            // `exec cat` exits on a single Ctrl+D and avoids ignore-eof shell settings.
            if let exitPanel = ws.terminalPanel(for: exitPanelId) {
                exitPanel.sendText("exec cat\r")
            }

            var exitPanelAttachedBeforeCtrlD = false
            var exitPanelHasSurfaceBeforeCtrlD = false
            if !useEarlyTrigger {
                let readiness = await self.waitForTerminalPanelReadyForUITest(
                    workspace: ws,
                    panelId: exitPanelId
                )
                exitPanelAttachedBeforeCtrlD = readiness.attached
                exitPanelHasSurfaceBeforeCtrlD = readiness.hasSurface
                if !(readiness.attached && readiness.hasSurface) {
                    write([
                        "exitTabAttachedBeforeCtrlD": readiness.attached ? "1" : "0",
                        "exitTabHasSurfaceBeforeCtrlD": readiness.hasSurface ? "1" : "0",
                        "setupError": "Exit panel not ready for Ctrl+D (not attached or surface nil)",
                        "done": "1",
                    ])
                    return
                }
                self.ensureFocusedTerminalFirstResponder()
            } else if let exitPanel = ws.terminalPanel(for: exitPanelId) {
                exitPanelAttachedBeforeCtrlD = exitPanel.surface.isViewInWindow
                exitPanelHasSurfaceBeforeCtrlD = exitPanel.surface.surface != nil
            }

            let focusedPanelBefore = ws.focusedPanelId?.uuidString ?? ""
            let firstResponderPanelBefore = ws.panels.compactMap { (panelId, panel) -> UUID? in
                guard let terminal = panel as? TerminalTab else { return nil }
                return terminal.hostedView.isSurfaceViewFirstResponder() ? panelId : nil
            }.first?.uuidString ?? ""

            write([
                "workspaceId": ws.id.uuidString,
                "leftTabId": leftPanelId.uuidString,
                "rightTabId": rightPanel.id.uuidString,
                "topRightTabId": topRightPanelId,
                "bottomLeftTabId": bottomLeftPanelId,
                "bottomRightTabId": bottomRightPanelId,
                "exitTabId": exitPanelId.uuidString,
                "tabCountBeforeCtrlD": String(ws.panels.count),
                "layout": layout,
                "expectedTabsAfter": String(expectedPanelsAfter),
                "focusedTabBefore": focusedPanelBefore,
                "firstResponderTabBefore": firstResponderPanelBefore,
                "exitTabAttachedBeforeCtrlD": exitPanelAttachedBeforeCtrlD ? "1" : "0",
                "exitTabHasSurfaceBeforeCtrlD": exitPanelHasSurfaceBeforeCtrlD ? "1" : "0",
                "ready": "1",
                "done": "0",
            ])

            var finished = false
            var timeoutWork: DispatchWorkItem?

            @MainActor
            func finish(_ updates: [String: String]) {
                guard !finished else { return }
                finished = true
                timeoutWork?.cancel()
                write(updates.merging(["done": "1"], uniquingKeysWith: { _, new in new }))
                self.uiTestCancellables.removeAll()
            }

            ws.$panels
                .map { $0.count }
                .removeDuplicates()
                .sink { [weak self, weak workspace = ws] count in
                    Task { @MainActor in
                        guard let self, let workspace else { return }
                        if count == expectedPanelsAfter {
                            // Require the post-exit state to be stable for a short window so
                            // we catch "close looked correct, then workspace vanished" races.
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            guard workspace.panels.count == expectedPanelsAfter else { return }

                            let firstResponderPanelAfter = workspace.panels.compactMap { (panelId, panel) -> UUID? in
                                guard let terminal = panel as? TerminalTab else { return nil }
                                return terminal.hostedView.isSurfaceViewFirstResponder() ? panelId : nil
                            }.first?.uuidString ?? ""

                            finish([
                                "workspaceCountAfter": String(self.workspaces.count),
                                "tabCountAfter": String(workspace.panels.count),
                                "closedWorkspace": self.workspaces.contains(where: { $0.id == workspace.id }) ? "0" : "1",
                                "focusedTabAfter": workspace.focusedPanelId?.uuidString ?? "",
                                "firstResponderTabAfter": firstResponderPanelAfter,
                            ])
                        }
                    }
                }
                .store(in: &uiTestCancellables)

            $workspaces
                .map { $0.contains(where: { $0.id == ws.id }) }
                .removeDuplicates()
                .sink { alive in
                    Task { @MainActor in
                        if !alive {
                            finish([
                                "workspaceCountAfter": "0",
                                "tabCountAfter": "0",
                                "closedWorkspace": "1",
                            ])
                        }
                    }
                }
                .store(in: &uiTestCancellables)

            let work = DispatchWorkItem {
                finish([
                    "workspaceCountAfter": String(self.workspaces.count),
                    "tabCountAfter": String(ws.panels.count),
                    "closedWorkspace": self.workspaces.contains(where: { $0.id == ws.id }) ? "0" : "1",
                    "timedOut": "1",
                ])
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)

            if autoTrigger {
                Task { @MainActor [weak workspace = ws] in
                    guard let workspace else { return }
                    write(["autoTriggerStarted": "1"])

                    if triggerMode == "runtime_close_callback" {
                        write(["autoTriggerMode": "runtime_close_callback"])
                        self.closePanelAfterChildExited(workspaceId: workspace.id, surfaceId: exitPanelId)
                        return
                    }

                    let triggerModifiers: NSEvent.ModifierFlags = triggerUsesShift
                        ? [.control, .shift]
                        : [.control]
                    let shouldWaitForSurface = !useEarlyTrigger

                    var attachedBeforeTrigger = false
                    var hasSurfaceBeforeTrigger = false
                    if shouldWaitForSurface {
                        let ready = await self.waitForTerminalTabCondition(
                            workspace: workspace,
                            panelId: exitPanelId,
                            timeoutSeconds: 5.0
                        ) { panel in
                            attachedBeforeTrigger = panel.surface.isViewInWindow
                            hasSurfaceBeforeTrigger = panel.surface.surface != nil
                            return attachedBeforeTrigger && hasSurfaceBeforeTrigger
                        }
                        if !ready,
                           workspace.terminalPanel(for: exitPanelId) == nil {
                            write(["autoTriggerError": "missingExitTabBeforeTrigger"])
                            return
                        }
                    } else if let panel = workspace.terminalPanel(for: exitPanelId) {
                        attachedBeforeTrigger = panel.surface.isViewInWindow
                        hasSurfaceBeforeTrigger = panel.surface.surface != nil
                    }
                    write([
                        "exitTabAttachedBeforeTrigger": attachedBeforeTrigger ? "1" : "0",
                        "exitTabHasSurfaceBeforeTrigger": hasSurfaceBeforeTrigger ? "1" : "0",
                    ])
                    if shouldWaitForSurface && !(attachedBeforeTrigger && hasSurfaceBeforeTrigger) {
                        write(["autoTriggerError": "exitTabNotReadyBeforeTrigger"])
                        return
                    }

                    guard let panel = workspace.terminalPanel(for: exitPanelId) else {
                        write(["autoTriggerError": "missingExitTabAtTrigger"])
                        return
                    }
                    // Exercise the real key path (ghostty_surface_key for Ctrl+D).
                    if panel.hostedView.sendSyntheticCtrlDForUITest(modifierFlags: triggerModifiers) {
                        write(["autoTriggerSentCtrlDKey1": "1"])
                    } else {
                        write([
                            "autoTriggerCtrlDKeyUnavailable": "1",
                            "autoTriggerError": "ctrlDKeyUnavailable",
                        ])
                        return
                    }

                    // In strict mode, never mask routing bugs with fallback writes.
                    if strictKeyOnly {
                        let strictModeLabel: String = {
                            if useEarlyCtrlShiftTrigger { return "strict_early_ctrl_shift_d" }
                            if useEarlyCtrlDTrigger { return "strict_early_ctrl_d" }
                            if triggerUsesShift { return "strict_ctrl_shift_d" }
                            return "strict_ctrl_d"
                        }()
                        write(["autoTriggerMode": strictModeLabel])
                        return
                    }

                    // Non-strict mode keeps one additional Ctrl+D retry for startup timing variance.
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if workspace.panels[exitPanelId] != nil,
                       panel.hostedView.sendSyntheticCtrlDForUITest(modifierFlags: triggerModifiers) {
                        write(["autoTriggerSentCtrlDKey2": "1"])
                    }
                }
            }
        }
    }
#endif
}

extension WorkspaceManager {
    func sessionAutosaveFingerprint() -> Int {
        var hasher = Hasher()
        hasher.combine(selectedWorkspaceId)
        hasher.combine(workspaces.count)
        // Tier 1 Phase 2: fold in the monotonic per-process revision counter
        // from SurfaceMetadataStore so metadata-only changes (which never
        // touch workspace/panel counts or titles) still flip the fingerprint
        // and trigger an autosave at the next 8s tick.
        hasher.combine(TabMetadataStore.shared.currentRevision())
        // CMUX-11 Phase 3: same trick for the pane store. Pane-only metadata
        // mutations (`pane.set_metadata`, --title seed on new-split) bump the
        // pane revision; including it here ensures those writes hit disk on
        // the same 8s cadence as surface metadata.
        hasher.combine(AreaMetadataStore.shared.currentRevision())

        for workspace in workspaces.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow) {
            hasher.combine(workspace.id)
            hasher.combine(workspace.focusedPanelId)
            hasher.combine(workspace.currentDirectory)
            hasher.combine(workspace.rootDirectory ?? "")
            hasher.combine(workspace.rootAdoptionArmed)
            hasher.combine(workspace.customTitle ?? "")
            hasher.combine(workspace.customColor ?? "")
            hasher.combine(workspace.isPinned)
            hasher.combine(workspace.panels.count)
            hasher.combine(workspace.statusEntries.count)
            hasher.combine(workspace.metadataBlocks.count)
            // Hash operator-authored workspace metadata by sorted keys so
            // value-only edits still change the fingerprint. Without this,
            // metadata edits could be deferred up to the forced-save window.
            hasher.combine(workspace.metadata.count)
            for key in workspace.metadata.keys.sorted() {
                hasher.combine(key)
                hasher.combine(workspace.metadata[key] ?? "")
            }
            hasher.combine(workspace.logEntries.count)
            hasher.combine(workspace.tabDirectories.count)
            hasher.combine(workspace.tabTitles.count)
            hasher.combine(workspace.tabPullRequests.count)
            hasher.combine(workspace.tabGitBranches.count)
            hasher.combine(workspace.tabListeningPorts.count)
            // Round five: which areas have their tab rail open.
            for railPane in workspace.bonsplitController.railOpenPaneIds.map({ $0.id.uuidString }).sorted() {
                hasher.combine(railPane)
            }

            if let progress = workspace.progress {
                hasher.combine(Int((progress.value * 1000).rounded()))
                hasher.combine(progress.label)
            } else {
                hasher.combine(-1)
            }

            if let gitBranch = workspace.gitBranch {
                hasher.combine(gitBranch.branch)
                hasher.combine(gitBranch.isDirty)
            } else {
                hasher.combine("")
                hasher.combine(false)
            }
        }

        return hasher.finalize()
    }

    func sessionSnapshot(
        includeScrollback: Bool,
        conversationsByPanelId conversationsByTabId: [String: TabConversations]? = nil
    ) -> SessionWorkspaceManagerSnapshot {
        let restorableTabs = workspaces
            .filter { !$0.isRemoteWorkspace }
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        // C11-170: thread the single pre-read store map (from
        // `AppDelegate.buildSessionSnapshot`) into every workspace so the
        // full-app save does one actor round-trip, not one per workspace.
        let workspaceSnapshots = restorableTabs
            .map { $0.sessionSnapshot(
                includeScrollback: includeScrollback,
                conversationsByPanelId: conversationsByTabId
            ) }
        let selectedWorkspaceIndex = selectedWorkspaceId.flatMap { selectedWorkspaceId in
            restorableTabs.firstIndex(where: { $0.id == selectedWorkspaceId })
        }
        return SessionWorkspaceManagerSnapshot(
            selectedWorkspaceIndex: selectedWorkspaceIndex,
            workspaces: workspaceSnapshots
        )
    }

    func restoreSessionSnapshot(_ snapshot: SessionWorkspaceManagerSnapshot) {
        for workspace in workspaces {
            unwireClosedBrowserTracking(for: workspace)
        }
        let existingProbeKeys = Set(workspaceGitProbeGenerationByKey.keys)
            .union(workspaceGitProbeTimersByKey.keys)
        for key in existingProbeKeys {
            clearWorkspaceGitProbe(key)
        }

        // Clear non-@Published state without touching tabs/selectedTabId yet.
        lastFocusedTabByWorkspace.removeAll()
        pendingTabTitleUpdates.removeAll()
        workspaceHistory.removeAll()
        historyIndex = -1
        isNavigatingHistory = false
        pendingWorkspaceUnfocusTarget = nil
        workspaceCycleCooldownTask?.cancel()
        workspaceCycleCooldownTask = nil
        isWorkspaceCycleHot = false
        selectionSideEffectsGeneration &+= 1
        recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: 20)

        // Build the new workspace list locally to avoid intermediate @Published
        // emissions (empty tabs, nil selectedTabId) that can leave SwiftUI's
        // mountedWorkspaceIds empty and cause a frozen blank launch state (#399).
        var newTabs: [Workspace] = []
        let workspaceSnapshots = snapshot.workspaces
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        for workspaceSnapshot in workspaceSnapshots {
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            // Tier 1 persistence, Phase 1.5: thread the snapshot's workspace
            // UUID into the restored workspace so `(workspaceId, surfaceId)`
            // tuples cached by external consumers (Lattice, CLI, scripted
            // tests) stay valid across restart.
            let workspace = Workspace(
                id: workspaceSnapshot.id,
                title: workspaceSnapshot.stableDefaultTitle ?? workspaceSnapshot.processTitle,
                stableDefaultTitle: workspaceSnapshot.stableDefaultTitle,
                workingDirectory: workspaceSnapshot.currentDirectory,
                rootDirectory: workspaceSnapshot.rootDirectory,
                portOrdinal: ordinal
            )
            workspace.owningWorkspaceManager = self
            workspace.restoreSessionSnapshot(workspaceSnapshot)
            wireClosedBrowserTracking(for: workspace)
            workspace.startMailboxDispatcher()
            newTabs.append(workspace)
        }

        if newTabs.isEmpty {
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let defaultTitle = Self.defaultWorkspaceTitle(number: 1)
            let fallback = Workspace(title: defaultTitle, stableDefaultTitle: defaultTitle, portOrdinal: ordinal)
            fallback.owningWorkspaceManager = self
            wireClosedBrowserTracking(for: fallback)
            fallback.startMailboxDispatcher()
            newTabs.append(fallback)
        }

        // Determine selection before mutating @Published properties.
        let newSelectedId: UUID?
        if let selectedWorkspaceIndex = snapshot.selectedWorkspaceIndex,
           newTabs.indices.contains(selectedWorkspaceIndex) {
            newSelectedId = newTabs[selectedWorkspaceIndex].id
        } else {
            newSelectedId = newTabs.first?.id
        }

        // Single atomic assignment of @Published properties so SwiftUI observers
        // never see an intermediate state with empty tabs or nil selection.
        workspaces = newTabs
        selectedWorkspaceId = newSelectedId
        for workspace in newTabs {
            let terminalTabs = workspace.panels.values.compactMap { $0 as? TerminalTab }
            for terminalTab in terminalTabs {
                guard let directory = gitProbeDirectory(for: workspace, panelId: terminalTab.id) else {
                    continue
                }
                scheduleInitialWorkspaceGitMetadataRefresh(
                    workspaceId: workspace.id,
                    panelId: terminalTab.id,
                    directory: directory
                )
            }
        }

        if let selectedWorkspaceId {
            NotificationCenter.default.post(
                name: .ghosttyDidFocusTab,
                object: nil,
                userInfo: [GhosttyNotificationKey.workspaceId: selectedWorkspaceId]
            )
        }
    }
}

// MARK: - Direction Types for Backwards Compatibility

/// Split direction for backwards compatibility with old API
enum SplitDirection {
    case left, right, up, down

    var isHorizontal: Bool {
        self == .left || self == .right
    }

    var orientation: SplitOrientation {
        isHorizontal ? .horizontal : .vertical
    }

    /// If true, insert the new pane on the "first" side (left/top).
    /// If false, insert on the "second" side (right/bottom).
    var insertFirst: Bool {
        self == .left || self == .up
    }
}

/// Resize direction for backwards compatibility
enum ResizeDirection {
    case left, right, up, down
}

extension Notification.Name {
    static let commandPaletteToggleRequested = Notification.Name("cmux.commandPaletteToggleRequested")
    static let commandPaletteRequested = Notification.Name("cmux.commandPaletteRequested")
    static let commandPaletteSwitcherRequested = Notification.Name("cmux.commandPaletteSwitcherRequested")
    static let commandPaletteSubmitRequested = Notification.Name("cmux.commandPaletteSubmitRequested")
    static let commandPaletteDismissRequested = Notification.Name("cmux.commandPaletteDismissRequested")
    static let commandPaletteRenameTabRequested = Notification.Name("cmux.commandPaletteRenameTabRequested")
    static let commandPaletteRenameWorkspaceRequested = Notification.Name("cmux.commandPaletteRenameWorkspaceRequested")
    static let commandPaletteMoveSelection = Notification.Name("cmux.commandPaletteMoveSelection")
    static let commandPaletteRenameInputInteractionRequested = Notification.Name("cmux.commandPaletteRenameInputInteractionRequested")
    static let commandPaletteRenameInputDeleteBackwardRequested = Notification.Name("cmux.commandPaletteRenameInputDeleteBackwardRequested")
    static let feedbackComposerRequested = Notification.Name("cmux.feedbackComposerRequested")
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")
    static let ghosttyDidFocusSurface = Notification.Name("ghosttyDidFocusSurface")
    static let ghosttyDidBecomeFirstResponderSurface = Notification.Name("ghosttyDidBecomeFirstResponderSurface")
    static let browserDidBecomeFirstResponderWebView = Notification.Name("browserDidBecomeFirstResponderWebView")
    static let browserFocusAddressBar = Notification.Name("browserFocusAddressBar")
    static let browserMoveOmnibarSelection = Notification.Name("browserMoveOmnibarSelection")
    static let browserDidExitAddressBar = Notification.Name("browserDidExitAddressBar")
    static let browserDidFocusAddressBar = Notification.Name("browserDidFocusAddressBar")
    static let browserDidBlurAddressBar = Notification.Name("browserDidBlurAddressBar")
    static let webViewDidReceiveClick = Notification.Name("webViewDidReceiveClick")
    static let terminalPortalVisibilityDidChange = Notification.Name("cmux.terminalPortalVisibilityDidChange")
    static let browserPortalRegistryDidChange = Notification.Name("cmux.browserPortalRegistryDidChange")
}
