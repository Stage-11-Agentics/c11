import AppKit
import SwiftUI

/// C11H-138: "Ask which machine for new terminals" (Settings, on by default).
enum MachinePickerSettings {
    static let askKey = "machinePicker.askForNewTerminals"
    static let defaultAsk = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: askKey) != nil else { return defaultAsk }
        return defaults.bool(forKey: askKey)
    }
}

/// What the operator is choosing a machine for; it titles the picker.
enum MachinePickerPurpose: Equatable {
    case terminal
    case agent(name: String)

    var title: String {
        switch self {
        case .terminal:
            return String(localized: "machinePicker.title.terminal", defaultValue: "New terminal on…")
        case .agent(let name):
            return String(
                format: String(localized: "machinePicker.title.agent", defaultValue: "Launch %@ on…"),
                name
            )
        }
    }
}

/// One row: this Mac, or a machine hc has linked.
struct MachinePickerRow: Equatable, Identifiable {
    /// `local`, or hc's machine name exactly as hc reports it.
    let id: String
    /// The number key that picks this row (1 to 9), nil past the ninth.
    let key: Int?
    let name: String
    /// Roster color (`#RRGGBB[AA]`), nil when the roster sets none.
    let color: String?
    let isLocal: Bool
    let connected: Bool
    /// C11H-274: c11 won't use this machine's stored link: listed with the
    /// reason, never picked.
    var unusable: Bool = false

    var isEnabled: Bool { isLocal || (connected && !unusable) }
    var request: HCMachineRequest { isLocal ? .local : .on(id) }

    var stateText: String {
        if isLocal {
            return String(localized: "machinePicker.state.thisMac", defaultValue: "This Mac")
        }
        if unusable {
            return String(localized: "machinePicker.state.unusable", defaultValue: "Link not used: Update or Remove in Settings")
        }
        return connected
            ? String(localized: "machinePicker.state.connected", defaultValue: "Connected")
            : String(localized: "machinePicker.state.down", defaultValue: "Link down")
    }
}

/// The picker's decisions, kept apart from AppKit so they are testable.
enum MachinePickerModel {
    enum Action: Equatable {
        case choose(HCMachineRequest)
        case cancel
        case ignore
    }

    /// Ask only when the setting is on and at least one other machine's link is
    /// up; otherwise the panel opens on this Mac exactly as before.
    static func shouldAsk(enabled: Bool, machines: [String: Bool]) -> Bool {
        enabled && machines.values.contains(true)
    }

    /// This Mac is 1, then hc's machines by name, numbered 2 to 9. A machine
    /// whose link is down is listed but cannot be picked.
    static func rows(
        machines: [String: Bool],
        unusable: Set<String> = [],
        roster: (String) -> MachineRosterEntry?,
        localHostName: String
    ) -> [MachinePickerRow] {
        let local = roster(MachineRoster.localID)
        var rows = [MachinePickerRow(
            id: MachineRoster.localID, key: 1, name: local?.name ?? localHostName,
            color: local?.color, isLocal: true, connected: true
        )]
        for (index, name) in machines.keys.sorted().enumerated() {
            let entry = roster(name)
            let key = index + 2
            rows.append(MachinePickerRow(
                id: name, key: key <= 9 ? key : nil,
                name: entry?.name ?? HCMachineTarget.displayName(name),
                color: entry?.color, isLocal: false, connected: machines[name] == true,
                unusable: unusable.contains(name)
            ))
        }
        return rows
    }

    static func action(digit: Int, rows: [MachinePickerRow]) -> Action {
        guard let row = rows.first(where: { $0.key == digit }), row.isEnabled else { return .ignore }
        return .choose(row.request)
    }

    static let returnAction: Action = .choose(.local)
    static let escapeAction: Action = .cancel
}

/// Main-actor entry point for every operator new-terminal and agent-launch path.
@MainActor
enum MachinePicker {
    /// Test and automation seam: when set, replaces the live machine list.
    static var machinesOverride: (() -> [String: Bool])?
    /// Test and automation seam: when set, replaces the live unusable-link set.
    static var unusableOverride: (() -> Set<String>)?

    static func liveMachines() -> [String: Bool] {
        if let machinesOverride { return machinesOverride() }
        return Dictionary(
            HCMachineDirectory.shared.entries.map { ($0.machine, $0.connected) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// C11H-274: machines whose stored link c11 won't use.
    static func liveUnusable() -> Set<String> {
        if let unusableOverride { return unusableOverride() }
        return HCMachineDirectory.shared.unusable
    }

    /// Calls `choose` with the operator's machine, at once with `.local` when
    /// there is nothing to ask. Escape or clicking away calls nothing.
    /// `anchorScreenRect` is the control the picker drops from; `nil` takes the
    /// control under the click that started this, if a click did, and
    /// otherwise the top of the window.
    static func ask(
        _ purpose: MachinePickerPurpose,
        in window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow,
        anchoringTo anchorScreenRect: NSRect? = nil,
        choose: @escaping (HCMachineRequest) -> Void
    ) {
        // Every caller is an operator gesture, and the picked row is the
        // operator's answer: what `choose` creates is theirs (C11H-260). A
        // socket request around a synchronous choice still wins.
        let operatorChoose: (HCMachineRequest) -> Void = { request in
            PanelLineage.shared.withOrigin(.operator) { choose(request) }
        }
        let machines = liveMachines()
        guard MachinePickerModel.shouldAsk(enabled: MachinePickerSettings.isEnabled(), machines: machines),
              let window else {
            operatorChoose(.local)
            return
        }
        let rows = MachinePickerModel.rows(
            machines: machines,
            unusable: liveUnusable(),
            roster: { MachineRoster.shared.entry(id: $0) },
            localHostName: LocalSessionPlacementFeed.localHostName
        )
        // Read the click now: by the next turn the current event is gone.
        let anchor = anchorScreenRect ?? clickedControlScreenRect(in: window)
        // Next turn: a sheet or the command palette that started this closes
        // first, so the transient popover does not lose the key window at once.
        DispatchQueue.main.async {
            MachinePickerPresenter.shared.present(purpose: purpose, rows: rows, in: window,
                                                  anchoringTo: anchor, choose: operatorChoose)
        }
    }

    /// The screen frame of the control under the mouse click being handled in
    /// `window` (a tab-bar button such as A), or a point at the click when the
    /// view under it is not a small control. `nil` for a key press, or a click
    /// in another window.
    static func clickedControlScreenRect(in window: NSWindow) -> NSRect? {
        guard let event = NSApp.currentEvent, event.window === window,
              [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
               .otherMouseDown, .otherMouseUp].contains(event.type),
              let frameView = window.contentView?.superview else { return nil }
        let point = event.locationInWindow
        // The frame view has no superview, so window coordinates are what
        // its hitTest expects.
        if let hit = frameView.hitTest(point) {
            let frame = hit.convert(hit.bounds, to: nil)
            if frame.width <= 120, frame.height <= 60, frame.width > 0, frame.height > 0 {
                return window.convertToScreen(frame)
            }
        }
        return window.convertToScreen(NSRect(x: point.x, y: point.y, width: 1, height: 1))
    }
}

struct MachinePickerView: View {
    let purpose: MachinePickerPurpose
    let rows: [MachinePickerRow]
    let onPick: (MachinePickerRow) -> Void

    static let width: CGFloat = 380
    static let rowHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(purpose.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                Button { onPick(row) } label: { rowView(row) }
                    .buttonStyle(.plain)
                    // Keys come from the presenter's monitor; no focus ring.
                    .focusable(false)
                    .disabled(!row.isEnabled)
                    .accessibilityIdentifier("MachinePickerRow.\(row.id)")
                    .accessibilityLabel(accessibilityLabel(row))
            }
            Text(String(localized: "machinePicker.hint", defaultValue: "Press a number. Return: This Mac. Esc: cancel."))
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.65))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .frame(width: Self.width, alignment: .leading)
        .background(Color(nsColor: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MachinePicker")
    }

    private func rowView(_ row: MachinePickerRow) -> some View {
        HStack(spacing: 12) {
            Text(row.key.map(String.init) ?? " ")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(row.key == nil ? 0 : 0.92)))
            Circle()
                .fill(row.color.flatMap(MachineRosterColor.nsColor).map { Color(nsColor: $0) } ?? Color.white.opacity(0.25))
                .frame(width: 12, height: 12)
            Text(row.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(row.stateText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(row.isEnabled ? Color.white.opacity(0.75) : Color.orange)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .opacity(row.isEnabled ? 1 : 0.45)
    }

    private func accessibilityLabel(_ row: MachinePickerRow) -> String {
        let key = row.key.map { String($0) + ", " } ?? ""
        return key + row.name + ", " + row.stateText
    }
}

/// Hosts the picker in an arrowless transient popover near the top of the
/// window, with a local key monitor. Never runs a modal loop.
@MainActor
final class MachinePickerPresenter: NSObject, NSPopoverDelegate {
    static let shared = MachinePickerPresenter()

    private var popover: NSPopover?
    private var keyMonitor: Any?
    private var rows: [MachinePickerRow] = []
    private var choose: ((HCMachineRequest) -> Void)?

    var isShown: Bool { popover?.isShown == true }

    func present(purpose: MachinePickerPurpose, rows: [MachinePickerRow], in window: NSWindow,
                 anchoringTo anchorScreenRect: NSRect? = nil,
                 choose: @escaping (HCMachineRequest) -> Void) {
        dismiss()
        // One picker at a time: the agent picker's number keys must not reach
        // this monitor, nor this picker's reach it.
        AgentPickerPresenter.shared.dismiss()
        guard let contentView = window.contentView else {
            choose(.local)
            return
        }
        self.rows = rows
        self.choose = choose

        let view = MachinePickerView(purpose: purpose, rows: rows) { [weak self] row in
            guard row.isEnabled else { return }
            self?.finish(.choose(row.request))
        }
        let host = NSHostingController(rootView: view.fixedSize())
        host.view.appearance = NSAppearance(named: .darkAqua)
        host.sizingOptions = [.preferredContentSize]

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.setValue(true, forKeyPath: "shouldHideAnchor")
        pop.contentViewController = host
        pop.delegate = self
        popover = pop

        let anchor: NSRect
        if let anchorScreenRect {
            // Drop from the control that asked (the A or terminal button), so
            // the question appears where the operator is looking.
            anchor = contentView.convert(window.convertFromScreen(anchorScreenRect), from: nil)
        } else {
            let bounds = contentView.bounds
            let topY = contentView.isFlipped ? bounds.minY + 44 : bounds.maxY - 44
            anchor = NSRect(x: bounds.midX, y: topY, width: 1, height: 1)
        }
        pop.show(relativeTo: anchor, of: contentView, preferredEdge: contentView.isFlipped ? .maxY : .minY)
        installKeyMonitor()
    }

    func dismiss() {
        removeKeyMonitor()
        let closing = popover
        popover = nil
        choose = nil
        closing?.performClose(nil)
        if closing != nil { resumeTips() }
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        removeKeyMonitor()
        popover = nil
        choose = nil
        resumeTips()
    }

    /// Tips held while the picker was open go next, on the following turn.
    private func resumeTips() {
        DispatchQueue.main.async { C11TipCenter.shared.resume() }
    }

    private func finish(_ action: MachinePickerModel.Action) {
        guard case .choose(let request) = action else {
            if action == .cancel { dismiss() }
            return
        }
        // The rows are a snapshot; a link that dropped while the picker was
        // open is refused here rather than failing after the pick.
        if case .on(let machine) = request,
           MachinePicker.liveMachines()[machine] != true || MachinePicker.liveUnusable().contains(machine) {
            NSSound.beep()
            return
        }
        let callback = choose
        dismiss()
        callback?(request)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover?.isShown == true else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard modifiers.isEmpty else { return event }
            switch event.keyCode {
            case 36, 76:
                self.finish(MachinePickerModel.returnAction)
                return nil
            case 53:
                self.finish(MachinePickerModel.escapeAction)
                return nil
            default:
                guard let characters = event.charactersIgnoringModifiers, let digit = Int(characters),
                      (1...9).contains(digit) else { return nil }
                self.finish(MachinePickerModel.action(digit: digit, rows: self.rows))
                return nil
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// C11H-396: why an operator's split or move made nothing, said where they
/// are looking: the refusal's own message (the one the CLI gives) in a small
/// transient popover over the panel it came from. It never takes the
/// keyboard, a click anywhere closes it, and it closes itself after a few
/// seconds. One at a time; a newer refusal replaces it. Silent under XCTest.
@MainActor
final class HCRefusalNotice: NSObject, NSPopoverDelegate {
    static let shared = HCRefusalNotice(suppressed: MessagesPageWriter.isRunningUnderXCTest())
    static let visibleSeconds: TimeInterval = 8

    private let suppressed: Bool
    private var popover: NSPopover?

    init(suppressed: Bool) {
        self.suppressed = suppressed
        super.init()
    }

    var isShown: Bool { popover?.isShown == true }

    /// Shows `message` hanging from `anchor` (a panel's top edge, or the window's).
    func show(_ message: String, anchor: C11TipAnchor?) {
        guard !suppressed, let anchor, let view = anchor.view, view.window != nil else { return }
        popover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: HCRefusalNoticeView(message: message))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        // Whichever window holds the keyboard keeps it.
        let keyWindow = NSApp.keyWindow
        self.popover = popover
        popover.show(relativeTo: anchor.rect, of: view, preferredEdge: anchor.edge)
        if let keyWindow, NSApp.keyWindow !== keyWindow { keyWindow.makeKey() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds) { [weak popover] in
            popover?.performClose(nil)
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard (notification.object as? NSPopover) === popover else { return }
            popover = nil
        }
    }
}

/// The refusal's message, as the CLI and the machine picker word it.
struct HCRefusalNoticeView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(Color(nsColor: .labelColor))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 320, alignment: .leading)
            .padding(14)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("HCRefusalNotice")
    }
}
