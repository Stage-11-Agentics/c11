import SwiftUI
import AppKit

// MARK: - Agent launch picker: SwiftUI view + presenter (C11-181, tier 1)
//
// Renders `AgentPickerModel` (the pure view-model) as the A-button launch popover,
// one-to-one with the binding prototype's `#popover`
// (`docs/design-prototypes/model-picker/index.html`). Row click = launch now; the
// pin glyph / ⌥-click = set default without launching. Keyboard ↑↓/⏎/⌥⏎/1–9/esc is
// driven by a local NSEvent monitor the presenter installs while the popover is open.
//
// The popover host is pinned to `.darkAqua` so the void palette renders correctly in
// either OS appearance (self-review F2); a live light-theme popover is the design's
// stated follow-up. All colors come from `BrandColors` + the local `PickerPalette`
// (the app's `surface2/surface3/goldGhost` have no shared token).

/// Local palette for the tokens `BrandColors` does not expose (exact prototype hex),
/// kept private so we never collide with another feature's shim.
private enum PickerPalette {
    /// #1f1f22
    static let surface2 = Color(red: 0x1f / 255, green: 0x1f / 255, blue: 0x22 / 255)
    /// #2d2d32
    static let surface3 = Color(red: 0x2d / 255, green: 0x2d / 255, blue: 0x32 / 255)
    /// gold @ 0.10 (the prototype's `--gold-ghost`)
    static let goldGhost = BrandColors.goldSwiftUI.opacity(0.10)
    /// sub-line provider segment brightness (prototype `rgba(232,232,232,0.55)`)
    static let subProvider = BrandColors.whiteSwiftUI.opacity(0.55)
    /// sub-line default segment (prototype `--dim`)
    static let subDim = BrandColors.dimSwiftUI
    static let popoverWidth: CGFloat = 462
}

// MARK: - Controller (ObservableObject bridging the value-type model to SwiftUI)

/// Owns the mutable picker state and the action callbacks the presenter/workspace
/// wire in. Reference type so the NSEvent key monitor can capture it safely.
final class AgentPickerController: ObservableObject {
    @Published var model: AgentPickerModel

    /// Launch a specific config now (row click / ⏎ / 1–9 / recent).
    var onLaunch: (SavedAgentConfig) -> Void = { _ in }
    /// Pin a config as default without launching (pin glyph / ⌥-click / ⌥⏎).
    var onPin: (SavedAgentConfig) -> Void = { _ in }
    /// Flip follow-recent mode.
    var onToggleFollowRecent: () -> Void = {}
    /// Open the tier-2 configure sheet (C11-182 seam).
    var onViewAll: () -> Void = {}
    /// Open the stats view (C11-182 seam).
    var onStats: () -> Void = {}
    /// Surface the "not installed" hint for a plain launch of a dim row (§5.6).
    var onNotInstalledHint: (SavedAgentConfig) -> Void = { _ in }
    /// Dismiss the popover (set by the presenter).
    var onClose: () -> Void = {}
    /// Rebuild the model from fresh store state (after a pin/toggle mutates disk),
    /// so the ● default marker and header update live without closing. Returns
    /// `nil` when the source is gone (workspace deallocated) — refresh is skipped.
    var rebuild: () -> AgentPickerModel? = { nil }

    init(model: AgentPickerModel) {
        self.model = model
    }

    // MARK: Key + gesture handling

    func handleKey(_ key: PickerKey, option: Bool, command: Bool = false) {
        dispatch(model.handleKey(key, option: option, command: command))
    }

    /// A pointer click on a shortlist row: ⌥ pins, a plain click launches (or hints
    /// when the harness is not installed).
    func clickRow(_ row: AgentPickerRow, option: Bool) {
        if option { pin(row.config); return }
        dispatch(row.isInstalled ? .launch(row.config) : .notInstalled(row.config))
    }

    func clickPinGlyph(_ row: AgentPickerRow) { pin(row.config) }

    func clickRecent() {
        dispatch(model.recentClickAction())
    }

    func toggleFollowRecent() {
        onToggleFollowRecent(); refresh()
    }

    private func pin(_ config: SavedAgentConfig) {
        onPin(config); refresh()
    }

    private func dispatch(_ action: PickerAction) {
        switch action {
        case .launch(let c): onLaunch(c); onClose()
        case .pin(let c): pin(c)                     // stays open, ● moves (prototype)
        case .notInstalled(let c): onNotInstalledHint(c)
        case .toggleFollowRecent: toggleFollowRecent()
        case .viewAll: onViewAll(); onClose()
        case .stats: onStats(); onClose()
        case .close: onClose()
        case .none: break
        }
    }

    /// Refresh the model in place (preserving the keyboard cursor) after a mutation.
    private func refresh() {
        guard var next = rebuild() else { return }
        let sel = model.selectedIndex
        // Max nav index = last shortlist row, plus the recent row when present.
        let maxSel = next.content.shortlist.count - 1 + (next.content.recent != nil ? 1 : 0)
        next.selectedIndex = min(max(sel, -1), maxSel)
        model = next
    }
}

// MARK: - The popover view

struct AgentPickerView: View {
    @ObservedObject var controller: AgentPickerController

    private var content: AgentPickerContent { controller.model.content }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(content.shortlist.enumerated()), id: \.element.config.id) { idx, row in
                PickerRowView(
                    row: row,
                    isFocused: controller.model.selectedIndex == idx,
                    followRecent: content.followRecent,
                    onClick: { opt in controller.clickRow(row, option: opt) },
                    onPin: { controller.clickPinGlyph(row) }
                )
                Divider().overlay(BrandColors.ruleSwiftUI.opacity(0.55))
            }
            if let recent = content.recent {
                sectionRule(String(localized: "agentPicker.recent.section", defaultValue: "recent"))
                RecentRowView(
                    row: recent,
                    isFocused: controller.model.selectedIndex == content.shortlist.count,
                    onClick: { controller.clickRecent() }
                )
            }
            footer
            hintBar
        }
        .frame(width: PickerPalette.popoverWidth)
        .background(BrandColors.surfaceSwiftUI)
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(BrandColors.ruleSwiftUI, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text(String(localized: "agentPicker.header.launchAgent", defaultValue: "Launch agent"))
                .ucLabel(color: BrandColors.whiteSwiftUI.opacity(0.7))
            Spacer()
            if content.followRecent {
                Text(String(localized: "agentPicker.header.following", defaultValue: "◉ following recent"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(BrandColors.goldSwiftUI)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { ruleLine }
    }

    private func sectionRule(_ label: String) -> some View {
        HStack(spacing: 8) {
            line
            Text(label).ucLabel()
            line
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(BrandColors.blackSwiftUI.opacity(0.5))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            FooterRow(
                icon: .checkbox(content.followRecent),
                label: String(localized: "agentPicker.footer.followRecent", defaultValue: "Default follows most recent"),
                trailingText: content.followRecent
                    ? String(localized: "agentPicker.footer.followRecent.hint", defaultValue: "A launches whatever you last launched")
                    : nil,
                trailingKbd: nil,
                action: { controller.toggleFollowRecent() }
            )
            FooterRow(
                icon: .glyph("✎"),
                label: String(localized: "agentPicker.footer.viewAll", defaultValue: "View all models & configs…"),
                trailingText: nil,
                trailingKbd: "⌘⏎",
                action: { controller.onViewAll(); controller.onClose() }
            )
            FooterRow(
                icon: .glyph("▤"),
                label: String(localized: "agentPicker.footer.stats", defaultValue: "Launch stats"),
                trailingText: content.statsHeadline,
                trailingKbd: nil,
                action: { controller.onStats(); controller.onClose() }
            )
        }
        .background(BrandColors.blackSwiftUI.opacity(0.6))
        .overlay(alignment: .top) { ruleLine }
    }

    private var hintBar: some View {
        HStack(spacing: 6) {
            KeyCap("↑↓"); hintText(String(localized: "agentPicker.hint.select", defaultValue: "select")); dot
            KeyCap("⏎"); hintText(String(localized: "agentPicker.hint.launch", defaultValue: "launch")); dot
            KeyCap("⌥⏎"); hintText(String(localized: "agentPicker.hint.setDefault", defaultValue: "set default")); dot
            KeyCap("1–9"); hintText(String(localized: "agentPicker.hint.launchNth", defaultValue: "launch nth"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(BrandColors.blackSwiftUI.opacity(0.75))
        .overlay(alignment: .top) { ruleLine }
    }

    // MARK: Bits

    private func hintText(_ s: String) -> some View {
        Text(s).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
    }
    private var dot: some View {
        Text("·").foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.25))
    }
    private var line: some View { Rectangle().fill(BrandColors.ruleSwiftUI).frame(height: 1) }
    private var ruleLine: some View { Rectangle().fill(BrandColors.ruleSwiftUI).frame(height: 1) }
}

// MARK: - Shortlist row

private struct PickerRowView: View {
    let row: AgentPickerRow
    let isFocused: Bool
    let followRecent: Bool
    let onClick: (Bool) -> Void
    let onPin: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            PinCell(isDefault: row.isPinnedDefault, hovering: hovering, onPin: onPin)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(BrandColors.whiteSwiftUI)
                    if row.isRecentDefault && followRecent {
                        DefaultTag(String(localized: "agentPicker.tag.recentDefault", defaultValue: "recent→default"))
                    } else if row.isPinnedDefault {
                        DefaultTag(String(localized: "agentPicker.tag.default", defaultValue: "default"))
                    }
                    if !row.isInstalled {
                        Text(String(localized: "agentPicker.notInstalled", defaultValue: "NOT INSTALLED"))
                            .font(.system(size: 8.5, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(BrandColors.dimSwiftUI)
                    }
                }
                SubLine(row.subLine)
            }
            Spacer(minLength: 6)
            HStack(spacing: 7) {
                if let sys = row.sysChip { SysChipView(sys) }
                if let effort = row.effortChip { EffortChipView(effort) }
                Text(row.cost ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.68))
                    .frame(minWidth: 82, alignment: .trailing)
                KeyCap("\(row.keyBadge)").frame(width: 16)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .opacity(row.isInstalled ? 1 : 0.42)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isFocused { Rectangle().fill(BrandColors.goldSwiftUI).frame(width: 2) }
        }
        .contentShape(Rectangle())
        // Hover is tracked even for not-installed rows so the pin ○ stays
        // discoverable (they remain pinnable); only the background highlight is
        // gated to installed rows (prototype: `.cfg-row.disabled:hover { transparent }`).
        .onHover { hovering = $0 }
        .onTapGesture { onClick(NSEvent.modifierFlags.contains(.option)) }
    }

    private var rowBackground: some View {
        Group {
            if isFocused { BrandColors.goldFaintSwiftUI }
            else if hovering && row.isInstalled { BrandColors.whiteSwiftUI.opacity(0.03) }
            else { Color.clear }
        }
    }
}

// MARK: - Recent row

private struct RecentRowView: View {
    let row: AgentPickerRecentRow
    let isFocused: Bool
    let onClick: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text("↻")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.55))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(BrandColors.whiteSwiftUI)
                    Text(row.relativeTime)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
                    if !row.isInstalled {
                        Text(String(localized: "agentPicker.notInstalled", defaultValue: "NOT INSTALLED"))
                            .font(.system(size: 8.5, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(BrandColors.dimSwiftUI)
                    }
                }
                SubLine(row.subLine, brightenProvider: false)
            }
            Spacer(minLength: 6)
            HStack(spacing: 7) {
                if row.showLiveHint { LiveHintBadge(harness: row.harnessDisplayName) }
                Text(row.cost ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.68))
                    .frame(minWidth: 82, alignment: .trailing)
                // Empty key-cap slot so the recent cost aligns with shortlist costs.
                Color.clear.frame(width: 16, height: 1)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .opacity(row.isInstalled ? 1 : 0.42)
        .background(isFocused ? BrandColors.goldFaintSwiftUI : (hovering && row.isInstalled ? BrandColors.whiteSwiftUI.opacity(0.03) : Color.clear))
        .overlay(alignment: .leading) {
            if isFocused { Rectangle().fill(BrandColors.goldSwiftUI).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onClick() }
    }
}

// MARK: - Small components

private struct PinCell: View {
    let isDefault: Bool
    let hovering: Bool
    let onPin: () -> Void

    var body: some View {
        ZStack {
            if isDefault {
                Text("●").font(.system(size: 11)).foregroundStyle(BrandColors.goldSwiftUI)
            } else {
                Text("○")
                    .font(.system(size: 10))
                    .foregroundStyle(hovering ? BrandColors.whiteSwiftUI.opacity(0.4) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { onPin() }
                    .help(String(localized: "agentPicker.pin.help", defaultValue: "Set as default (⌥-click)"))
            }
        }
        .frame(width: 20)
    }
}

private struct DefaultTag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(BrandColors.goldSwiftUI)
            .padding(.horizontal, 4).padding(.vertical, 0.5)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(BrandColors.goldFaintSwiftUI, lineWidth: 0.5))
    }
}

/// `harness · provider · model` with the provider segment brightened (prototype).
private struct SubLine: View {
    let text: String
    /// Shortlist sub-lines are `harness · provider · model` — brighten the middle
    /// (provider). The recent sub-line is `harness · model · effort`, which has no
    /// provider span, so it stays fully dim (prototype `.cfg-sub` with no `.prov`).
    let brightenProvider: Bool
    init(_ text: String, brightenProvider: Bool = true) {
        self.text = text
        self.brightenProvider = brightenProvider
    }
    var body: some View {
        let parts = text.components(separatedBy: " · ")
        return HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 {
                    Text(" · ").foregroundStyle(PickerPalette.subDim)
                }
                Text(part).foregroundStyle(brightenProvider && parts.count == 3 && i == 1 ? PickerPalette.subProvider : PickerPalette.subDim)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .lineLimit(1)
    }
}

private struct EffortChipView: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.75))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(PickerPalette.surface3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(BrandColors.ruleSwiftUI, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct SysChipView: View {
    let sys: PickerSysChip
    init(_ sys: PickerSysChip) { self.sys = sys }
    var body: some View {
        Text(sys.label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(BrandColors.goldSwiftUI)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(PickerPalette.goldGhost)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(BrandColors.goldFaintSwiftUI, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.78))
            .padding(.horizontal, 4).padding(.vertical, 0.5)
            .background(PickerPalette.surface3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(BrandColors.ruleSwiftUI, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// The quiet ⓘ hint on a non-claude recent row (design §8.4).
private struct LiveHintBadge: View {
    let harness: String
    @State private var hovering = false
    var body: some View {
        Text("i")
            .font(.system(size: 8.5, design: .monospaced))
            .foregroundStyle(hovering ? BrandColors.goldSwiftUI : BrandColors.dimSwiftUI)
            .frame(width: 13, height: 13)
            .overlay(Circle().stroke(hovering ? BrandColors.goldFaintSwiftUI : BrandColors.ruleSwiftUI, lineWidth: 0.5))
            .onHover { hovering = $0 }
            .help(String(
                localized: "agentPicker.recent.liveHint",
                defaultValue: "\(harness) does not report live model changes — this value was captured at launch. A mid-session /model switch inside the TUI is not observed."
            ))
    }
}

// MARK: - Footer row

private struct FooterRow: View {
    enum Icon { case checkbox(Bool), glyph(String) }
    let icon: Icon
    let label: String
    let trailingText: String?
    let trailingKbd: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            iconView.frame(width: 16)
            Text(label)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(hovering ? BrandColors.whiteSwiftUI : BrandColors.whiteSwiftUI.opacity(0.8))
            Spacer(minLength: 6)
            if let t = trailingText {
                Text(t).font(.system(size: 10, design: .monospaced)).foregroundStyle(BrandColors.dimSwiftUI)
            }
            if let k = trailingKbd { KeyCap(k) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(hovering ? BrandColors.whiteSwiftUI.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { action() }
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .checkbox(let on): CheckboxGlyph(on: on)
        case .glyph(let g):
            Text(g).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(hovering ? BrandColors.goldSwiftUI : BrandColors.dimSwiftUI)
        }
    }
}

private struct CheckboxGlyph: View {
    let on: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(on ? BrandColors.goldSwiftUI : Color.clear)
            .frame(width: 13, height: 13)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? BrandColors.goldSwiftUI : BrandColors.dimSwiftUI, lineWidth: 1))
            .overlay(
                Text(on ? "✓" : "")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(BrandColors.blackSwiftUI)
            )
    }
}

// MARK: - View helpers

private extension View {
    func ucLabel(color: Color = BrandColors.dimSwiftUI) -> some View {
        self.font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

// MARK: - Harness install probe (best-effort PATH lookup, cached)

/// Cached "is this harness on PATH?" probe (design §5.6). No such probe exists in
/// the repo, so this is a small first cut: look up the harness's factory-command
/// executable across the app PATH plus the usual user bin dirs. Biased toward
/// "installed" (a GUI app's PATH is narrow; a spurious dim is worse than none — a
/// forced launch still degrades to the shell's own error, and the row stays
/// pinnable). Cached per kind for the session.
enum AgentHarnessInstallProbe {
    private static let lock = NSLock()
    private static var cache: [String: Bool] = [:]

    /// Extra dirs a login shell usually has but a Finder-launched GUI app may not.
    private static let extraDirs: [String] = {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
            "\(home)/.cargo/bin", "\(home)/go/bin",
        ]
    }()

    static func isInstalled(_ harnessKind: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[harnessKind] { return cached }
        let result = probe(harnessKind)
        cache[harnessKind] = result
        return result
    }

    private static func probe(_ harnessKind: String) -> Bool {
        guard let manifest = AgentRegistry.shared.manifest(forKind: harnessKind) else {
            return true // custom / unknown kind — let the shell surface any error
        }
        guard let exe = manifest.factoryCommand.split(separator: " ").first.map(String.init), !exe.isEmpty else {
            return true
        }
        if exe.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: exe) }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in pathDirs + extraDirs {
            let candidate = (dir as NSString).appendingPathComponent(exe)
            if FileManager.default.isExecutableFile(atPath: candidate) { return true }
        }
        return false
    }
}

// MARK: - Presenter (NSPopover host + key monitor)

/// App-lifetime presenter that hosts the picker in an arrowless `NSPopover` anchored
/// to a rect on the window's contentView, and owns the local keyDown monitor's
/// install/teardown (self-review F3/F4).
final class AgentPickerPresenter: NSObject, NSPopoverDelegate {
    static let shared = AgentPickerPresenter()

    private var popover: NSPopover?
    private var keyMonitor: Any?
    private weak var controller: AgentPickerController?

    /// Present the picker. `screenPoint` anchors under the right-clicked A button
    /// (pointer path); `nil` anchors at the window's top-trailing corner (⌘⇧A / menu).
    ///
    /// Re-entry policy: only the keyboard path (nil `screenPoint`) toggles closed —
    /// pressing ⌘⇧A again dismisses. The pointer path is idempotent: if the popover
    /// is already shown, a repeat present is a no-op, so a double-evaluated
    /// `.contextMenu` builder within one right-click can't open-then-close (flicker).
    func present(controller: AgentPickerController, in window: NSWindow, at screenPoint: NSPoint?) {
        if let p = popover, p.isShown {
            if screenPoint == nil { dismiss() }
            return
        }
        guard let contentView = window.contentView else { return }

        self.controller = controller
        controller.onClose = { [weak self] in self?.dismiss() }

        let host = NSHostingController(rootView: AgentPickerView(controller: controller).fixedSize())
        host.view.appearance = NSAppearance(named: .darkAqua)   // F2: void chrome in any OS mode
        host.sizingOptions = [.preferredContentSize]

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.setValue(true, forKeyPath: "shouldHideAnchor")      // arrowless
        pop.contentViewController = host
        pop.delegate = self
        self.popover = pop

        let rect: NSRect
        if let sp = screenPoint {
            let winPt = window.convertPoint(fromScreen: sp)
            let cvPt = contentView.convert(winPt, from: nil)
            rect = NSRect(x: cvPt.x, y: cvPt.y, width: 1, height: 1)
        } else {
            let b = contentView.bounds
            // Top-trailing corner (contentView is a flipped NSHostingView: minY = top).
            let topY = contentView.isFlipped ? b.minY : b.maxY
            rect = NSRect(x: b.maxX - 130, y: topY, width: 1, height: 1)
        }
        // Drop the popover downward from the anchor in either coordinate convention:
        // on a flipped view "below" is the maxY edge, on a non-flipped view it's minY.
        // (NSPopover self-corrects if there's no room, but pick the right side first.)
        let preferredEdge: NSRectEdge = contentView.isFlipped ? .maxY : .minY
        pop.show(relativeTo: rect, of: contentView, preferredEdge: preferredEdge)
        installKeyMonitor()
    }

    func dismiss() {
        removeKeyMonitor()
        popover?.performClose(nil)
        popover = nil
        controller = nil
    }

    func popoverDidClose(_ notification: Notification) {
        // Ignore a delayed close callback for a popover we've already replaced —
        // otherwise a rapid toggle/reopen inside the close animation would let the
        // stale close tear down the NEW popover's key monitor + presenter state.
        guard (notification.object as? NSPopover) === popover else { return }
        removeKeyMonitor()
        popover = nil
        controller = nil
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Gate on the popover being shown. (A tighter "event belongs to the
            // popover's own window" check was considered but deferred: an .transient
            // popover already auto-dismisses on outside interaction, so the
            // shown-but-not-key window is negligible, and the window-identity
            // assumption can't be verified without a runtime pass.)
            guard let self, let controller = self.controller, self.popover?.isShown == true else { return event }
            let option = event.modifierFlags.contains(.option)
            let command = event.modifierFlags.contains(.command)
            let key: PickerKey?
            switch event.keyCode {
            case 125: key = .down
            case 126: key = .up
            case 36, 76: key = .enter
            case 53: key = .escape
            default:
                if let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
                    key = .digit(n)
                } else {
                    key = nil
                }
            }
            guard let k = key else { return event }
            controller.handleKey(k, option: option, command: command)
            return nil // swallow handled keys
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}
