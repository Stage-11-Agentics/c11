import AppKit
import SwiftUI

/// c11h: the Herder Topography settings page. A herder core (hc) is the small
/// background program on each machine that holds that machine's terminals.
/// This page explains that idea, draws every machine on one map with a gear
/// to edit it, and adds machines.

enum HerderTopography {
    /// `count` points evenly spaced on a circle, the first at the top, clockwise.
    static func points(count: Int, center: CGPoint, radius: CGFloat) -> [CGPoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(count)
            return CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                           y: center.y + radius * CGFloat(sin(angle)))
        }
    }

    /// Where a node's label sits: pushed outward from the center so it never
    /// covers the rings, further on the sides where the label is wide.
    static func labelCenter(for point: CGPoint, center: CGPoint, radius: CGFloat) -> CGPoint {
        guard radius > 0 else { return CGPoint(x: point.x, y: point.y + 34) }
        let ux = (point.x - center.x) / radius
        let uy = (point.y - center.y) / radius
        return CGPoint(x: point.x + ux * 62, y: point.y + uy * 36)
    }

    /// The prompt the help sheet copies, for an operator who would rather
    /// have an agent link the machine.
    static var agentPrompt: String {
        String(localized: "herderTopography.agentPrompt", defaultValue: """
        A small spell for linking a machine to c11.

        You are helping me add another machine to my c11 topography. c11 is a terminal app whose terminals live in a herder core (hc): a small background program, one per machine, that keeps terminals and their agents running even when the app quits. Linking a machine installs c11's herder core and its relay there over SSH and connects it, so terminals on that machine open in my c11 window. Nothing else on that machine changes.

        1. Run `c11 guide` and read what it says about `c11 machine`. A command missing from that guide does not exist in this build.
        2. If I have not named the machine, ask me which one. It needs SSH from this Mac with a key and no password prompt (a Tailscale name works), and either Apple silicon with the Xcode Command Line Tools, or x86-64 Linux with systemd, Python 3 and linger.
        3. Check it before touching anything: `ssh -o BatchMode=yes <host> 'uname -sm'` should print `Darwin arm64` or `Linux x86_64`. On a Mac, `xcode-select -p` should print a path; on Linux, `loginctl show-user "$USER" -p Linger` should say `Linger=yes`. If not, stop and tell me plainly what is missing and the one command that fixes it.
        4. Show me the exact command and wait for my yes: `c11 machine link --host <host>`. Linking is my call; add `--yes` only after I say so.
        5. Confirm with `c11 machine list` that it shows as connected. Then offer a display name and a color for its chip: `c11 machine set --id <machine> --name "<name>" --color "#RRGGBB"`.
        6. Report back in three lines: what you linked, how you checked it, and anything left for me.

        A few quiet enchantments, if you are willing:
        - Be a good guest. Leave the other machine exactly as you found it, plus one herder core.
        - An error is a clue, not a verdict. Read it, name it, and try the smallest next step.
        - When you suggest a color, choose the one you think the machine would pick for itself.
        - When it connects, a new star has joined the constellation. You may say so, briefly.
        """)
    }
}

// MARK: - The explainer

/// Three illustrated panels at the top of the page: what a herder core is,
/// why it matters, and what linking another machine gives you.
struct HerderTopographyExplainer: View {
    @State private var showingHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "herderTopography.explainer.title",
                            defaultValue: "Your terminals can live on more than one machine"))
                    .font(.system(size: 15, weight: .semibold))
                Text(String(localized: "herderTopography.explainer.lede",
                            defaultValue: "In most terminal apps a terminal lives inside the window. In c11 it lives in a herder core, so it can run on any Mac you link and keep running when the window goes away."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 10) {
                ExplainerTile(
                    number: 1,
                    title: String(localized: "herderTopography.explainer.one.title", defaultValue: "A herder core holds your terminals"),
                    text: String(localized: "herderTopography.explainer.one.body",
                                 defaultValue: "Every machine runs one small background program, its herder core (hc). Your shells and agents run inside it, not inside the c11 window.")
                ) { CoreIllustration() }
                ExplainerTile(
                    number: 2,
                    title: String(localized: "herderTopography.explainer.two.title", defaultValue: "They outlive the app"),
                    text: String(localized: "herderTopography.explainer.two.body",
                                 defaultValue: "Quit c11, update it, or restart it: the herder core keeps every terminal and agent running. Reopen c11 and you are right where you were.")
                ) { SurvivesIllustration() }
                ExplainerTile(
                    number: 3,
                    title: String(localized: "herderTopography.explainer.three.title", defaultValue: "One window, many machines"),
                    text: String(localized: "herderTopography.explainer.three.body",
                                 defaultValue: "Link another Mac and its herder core joins the map below. Open terminals on it from here; the chip on each panel names where it runs.")
                ) { ManyMachinesIllustration() }
            }
            Button {
                showingHelp = true
            } label: {
                Label(String(localized: "herderTopography.explainer.learnMore", defaultValue: "Learn more, or have your agent set it up"),
                      systemImage: "questionmark.circle")
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("HerderTopographyLearnMore")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
        )
        .sheet(isPresented: $showingHelp) {
            HerderTopographyHelpSheet(onAddMachine: nil) { showingHelp = false }
        }
    }
}

private struct ExplainerTile<Art: View>: View {
    let number: Int
    let title: String
    let text: String
    @ViewBuilder let art: () -> Art

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            art()
                .frame(maxWidth: .infinity)
                .frame(height: 86)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
                )
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A Mac, and under it the hc box with three terminals in it.
private struct CoreIllustration: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            HCBox(glowing: true)
        }
    }
}

/// The app window, closed, and the hc box still running.
private struct SurvivesIllustration: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: "macwindow")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .offset(y: 3)
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            HCBox(glowing: true)
        }
    }
}

/// This Mac in the middle, linked to two other machines, each with its own hc.
private struct ManyMachinesIllustration: View {
    var body: some View {
        HStack(spacing: 6) {
            MachineGlyph(symbol: "desktopcomputer")
            LinkLine()
            VStack(spacing: 2) {
                Image(systemName: "macwindow")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                Text("c11")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LinkLine()
            MachineGlyph(symbol: "macmini")
        }
    }
}

private struct MachineGlyph: View {
    let symbol: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            Text("hc")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.25)))
        }
    }
}

private struct LinkLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.green.opacity(0.6))
            .frame(width: 16, height: 1.5)
    }
}

/// The herder core: a labeled box holding three terminals.
private struct HCBox: View {
    let glowing: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Text("hc")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.green.opacity(glowing ? 0.18 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.green.opacity(0.6), lineWidth: 1))
        )
    }
}

// MARK: - The map

/// Every machine on one ring around c11: this Mac, every machine hc has
/// linked, and roster entries for machines no longer linked. A gear beside
/// each opens its editor; the ghost slot on the ring adds a machine.
struct HerderTopographyMapSection: View {
    @ObservedObject private var roster = MachineRoster.shared
    @ObservedObject private var directory = HCMachineDirectory.shared
    @ObservedObject private var hcStatus = MachineHCStatus.shared
    @State private var statusMessage: String?
    @State private var statusIsError = false
    /// The machine whose gear popover is open.
    @State private var editing: String?
    /// C11H-126 part 2: the Add Machine (or Update) sheet, and Remove.
    @State private var setupRequest: AddMachineRequest?
    @State private var removeRequest: RemoveMachineRequest?
    @State private var showingHelp = false

    private static let mapHeight: CGFloat = 340

    private var rows: [MachineRosterRow] {
        _ = roster.revision
        return MachineRosterRow.rows(
            roster: roster.all(),
            // C11H-359: a refused machine is still hc's, so it gets a row with Remove.
            linked: Dictionary(directory.entries.map { ($0.machine, $0.connected) } + directory.refused.keys.map { ($0, false) },
                               uniquingKeysWith: { a, _ in a }),
            localHostName: LocalSessionPlacementFeed.localHostName
        )
    }

    private var versions: [String: String] {
        var versions: [String: String] = [:]
        for (name, listed) in hcStatus.machines {
            if let id = MachineRoster.normalizedID(name), let version = listed.version { versions[id] = version }
        }
        if let pin = hcStatus.pinVersion { versions[MachineRoster.localID] = pin }
        return versions
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            map(rows)
                .frame(height: Self.mapHeight)
                .padding(.horizontal, 8)
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Button {
                    setupRequest = AddMachineRequest(host: "", name: nil, update: false)
                } label: {
                    Label(String(localized: "settings.machines.add", defaultValue: "Add Machine…"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .accessibilityIdentifier("SettingsMachineAdd")
                Button {
                    showingHelp = true
                } label: {
                    Label(String(localized: "herderTopography.help.button", defaultValue: "What is this?"), systemImage: "questionmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("HerderTopographyHelp")
                Text(String(localized: "settings.machines.add.hint", defaultValue: "Link another Mac over SSH so its terminals open here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("SettingsMachineStatus")
            }
        }
        .onAppear { hcStatus.refresh() }
        .sheet(item: $setupRequest) { request in
            AddMachineSheet(request: request) { setupRequest = nil }
        }
        .sheet(item: $removeRequest) { request in
            RemoveMachineSheet(request: request) { message, isError in
                removeRequest = nil
                if let message {
                    statusMessage = message
                    statusIsError = isError
                }
            }
        }
        .sheet(isPresented: $showingHelp) {
            HerderTopographyHelpSheet(onAddMachine: {
                showingHelp = false
                setupRequest = AddMachineRequest(host: "", name: nil, update: false)
            }) { showingHelp = false }
        }
    }

    private func map(_ rows: [MachineRosterRow]) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(40, min(size.width / 2 - 120, size.height / 2 - 66))
            // One more slot than machines: the last is the ghost Add slot.
            let points = HerderTopography.points(count: rows.count + 1, center: center, radius: radius)
            ZStack {
                Canvas { context, _ in
                    drawRings(context, center: center, radius: radius)
                    for (index, row) in rows.enumerated() {
                        var spoke = Path()
                        spoke.move(to: center)
                        spoke.addLine(to: points[index])
                        let style = row.isLocal || row.connected == true
                            ? StrokeStyle(lineWidth: 1.5)
                            : StrokeStyle(lineWidth: 1.2, dash: [3, 4])
                        context.stroke(spoke, with: .color(stateColor(row).opacity(0.55)), style: style)
                    }
                }
                hub.position(center)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    nodeDot(row).position(points[index])
                    nodeLabel(row)
                        .position(HerderTopography.labelCenter(for: points[index], center: center, radius: radius))
                }
                ghostSlot(at: points[rows.count],
                          labelAt: HerderTopography.labelCenter(for: points[rows.count], center: center, radius: radius))
            }
        }
    }

    private func drawRings(_ context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        for (scale, opacity) in [(1.0, 0.35), (0.62, 0.22), (1.32, 0.12)] as [(CGFloat, Double)] {
            let r = radius * scale
            let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            context.stroke(ring, with: .color(Color.secondary.opacity(opacity)),
                           style: StrokeStyle(lineWidth: 1, dash: scale == 1.0 ? [] : [2, 5]))
        }
    }

    private var hub: some View {
        VStack(spacing: 2) {
            Image(systemName: "macwindow")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
            Text("c11")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "herderTopography.hub", defaultValue: "c11, which shows every herder core"))
    }

    private func stateColor(_ row: MachineRosterRow) -> Color {
        if row.isLocal || row.connected == true { return .green }
        return row.linked ? .orange : .gray
    }

    private func stateLabel(_ row: MachineRosterRow) -> String {
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

    private func nodeDot(_ row: MachineRosterRow) -> some View {
        let fill = row.entry?.color.flatMap { MachineRosterColor.nsColor($0) }.map { Color(nsColor: $0) } ?? stateColor(row)
        return ZStack {
            Circle()
                .fill(stateColor(row).opacity(0.18))
                .frame(width: 26, height: 26)
            Circle()
                .strokeBorder(stateColor(row), lineWidth: 1.5)
                .frame(width: 26, height: 26)
            Circle()
                .fill(fill)
                .frame(width: 13, height: 13)
        }
        .help(stateLabel(row))
    }

    private func nodeLabel(_ row: MachineRosterRow) -> some View {
        let detail = [stateLabel(row), versions[row.id].map { "hc " + $0 }].compactMap { $0 }.joined(separator: " · ")
        return VStack(spacing: 1) {
            HStack(spacing: 4) {
                Text(row.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button {
                    editing = row.id
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(format: String(localized: "herderTopography.gear.help", defaultValue: "Edit %@"), row.displayName))
                .accessibilityLabel(String(format: String(localized: "herderTopography.gear.help", defaultValue: "Edit %@"), row.displayName))
                .accessibilityIdentifier("HerderTopographyGear.\(row.id)")
                .popover(isPresented: Binding(
                    get: { editing == row.id },
                    set: { if !$0, editing == row.id { editing = nil } }
                ), arrowEdge: .bottom) {
                    editor(row)
                }
            }
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle((hcStatus.needsUpdate(row.id) && row.linked || directory.refused[row.id] != nil) && !row.isLocal ? Color.orange : Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: 170)
    }

    private func ghostSlot(at point: CGPoint, labelAt labelPoint: CGPoint) -> some View {
        ZStack {
            Button {
                setupRequest = AddMachineRequest(host: "", name: nil, update: false)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: 26, height: 26)
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "settings.machines.add", defaultValue: "Add Machine…"))
            .accessibilityIdentifier("HerderTopographyGhostAdd")
            .position(point)
            Text(String(localized: "herderTopography.ghost", defaultValue: "add a machine"))
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .position(labelPoint)
                .allowsHitTesting(false)
        }
    }

    private func editor(_ row: MachineRosterRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.displayName)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
            Text(String(localized: "herderTopography.editor.note",
                        defaultValue: "The name and color show on the chip in each panel's bar. An empty field keeps the default."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            let links = linkSessions(row)
            let actions = MachineLinkActions.decide(own: links.own, c11h: links.c11h, isLocal: row.isLocal,
                                                    ownNote: updateNote(row),
                                                    ownOffersUpdate: directory.refused[row.id].map { $0 == .missingID } ?? true)
            MachineRosterSettingsRow(
                row: row, onSave: save, onRemove: remove,
                hcNote: actions.note,
                offersUpdate: actions.offersUpdate,
                onUpdate: {
                    editing = nil
                    // C11H-332: Update reuses the SSH target the machine was linked through.
                    // C11H-391: Link Again reads c11h's entry (same name and target, a
                    // first link in c11's own session); Update reads c11's own.
                    let linked = actions.targetSession.flatMap { hcStatus.bySession[$0]?[row.id] } ?? hcStatus.machines[row.id]
                    let target = linked.flatMap { HCMachineSetup.viaScript(for: $0, home: FileManager.default.homeDirectoryForCurrentUser) }
                        .flatMap { HCMachineSetup.ViaInfo.parse($0)?.target }
                    setupRequest = AddMachineRequest(host: target ?? linked?.host ?? row.id, name: row.id,
                                                     update: actions.update)
                },
                onRemoveMachine: {
                    editing = nil
                    removeRequest = RemoveMachineRequest(machine: row.id, name: row.displayName,
                                                         session: actions.removeSession)
                },
                linksAgain: actions.linksAgain,
                onRemoveC11hLink: actions.removeC11hLinkSession.map { c11h in
                    {
                        editing = nil
                        removeRequest = RemoveMachineRequest(machine: row.id, name: row.displayName, session: c11h)
                    }
                }
            )
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 540)
        .padding(.bottom, 4)
    }

    /// C11H-391: the sessions that link this name: c11's own (the links
    /// session while adopted) and c11h's (an adopted c11h session's link).
    private func linkSessions(_ row: MachineRosterRow) -> (own: String?, c11h: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let links = directory.links(of: row.id)
        let c11h = links.first { MachineRemoval.isC11hLink(viaPath: nil, session: $0.session, home: home) }?.session
        let own = links.first { !MachineRemoval.isC11hLink(viaPath: nil, session: $0.session, home: home) }?.session
        return (own, c11h)
    }

    /// C11H-359: why c11 refused a machine hc lists.
    static func refusedNote(_ reason: HCMachineRefusal) -> String {
        switch reason {
        case .missingID:
            return String(localized: "settings.machines.refused.missingID",
                          defaultValue: "c11 won't use this machine: hc lists it with no core id. Remove it, or Update to link it again.")
        case .localCoreID:
            return String(localized: "settings.machines.refused.localCoreID",
                          defaultValue: "c11 won't use this machine: it reports this Mac's own core id. Remove it.")
        case .duplicate:
            return String(localized: "settings.machines.refused.duplicate",
                          defaultValue: "c11 won't use this machine: hc lists its name or core id twice. Remove the one you don't know.")
        }
    }

    /// "hc 0.1.15 here, this app uses 0.1.16" for a linked machine that needs an update.
    private func updateNote(_ row: MachineRosterRow) -> String? {
        if !row.isLocal, let reason = directory.refused[row.id] {
            return Self.refusedNote(reason)
        }
        guard !row.isLocal, row.linked, hcStatus.needsUpdate(row.id) else { return nil }
        let theirs = hcStatus.machines[row.id]?.version ?? "?"
        if hcStatus.linkUnchecked(row.id) {
            // C11H-332: its link doesn't check the pin and c11 couldn't
            // migrate it (`HCStoredLinks`), so c11 won't use it.
            return String(localized: "settings.machines.needsPinCheck",
                          defaultValue: "c11 won't use this link; hc may still redial it until you Update or Remove it.")
        }
        return String(format: String(localized: "settings.machines.needsUpdate",
                                     defaultValue: "Runs hc %1$@; this c11 uses %2$@."),
                      theirs, hcStatus.pinVersion ?? "?")
    }

    private func save(_ id: String, _ name: String, _ hex: String) {
        do {
            try roster.set(id: id, name: .set(name), color: .set(hex))
            statusMessage = String(localized: "settings.machines.saved", defaultValue: "Machine saved.")
            statusIsError = false
        } catch MachineRosterError.invalidColor {
            statusMessage = String(localized: "settings.machines.invalidColor", defaultValue: "Use a hex color: #RRGGBB or #RRGGBBAA.")
            statusIsError = true
        } catch MachineRosterError.invalidName {
            statusMessage = String(localized: "settings.machines.invalidName", defaultValue: "Use a name of 1 to 48 characters on one line.")
            statusIsError = true
        } catch {
            statusMessage = String(localized: "settings.machines.saveError", defaultValue: "Could not save this machine.")
            statusIsError = true
        }
    }

    private func remove(_ id: String) {
        do {
            try roster.remove(id: id)
            statusMessage = String(localized: "settings.machines.reset", defaultValue: "Machine reset to its default.")
            statusIsError = false
        } catch {
            statusMessage = String(localized: "settings.machines.saveError", defaultValue: "Could not save this machine.")
            statusIsError = true
        }
    }
}

// MARK: - Help

/// What a herder core is, what adding a machine does and needs, and a prompt
/// to hand the job to an agent.
struct HerderTopographyHelpSheet: View {
    /// Nil hides the sheet's Add Machine button.
    let onAddMachine: (() -> Void)?
    let onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "herderTopography.help.title", defaultValue: "What is a herder core?"))
                .font(.system(size: 17, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    paragraph(String(localized: "herderTopography.help.what",
                                     defaultValue: "A herder core (hc) is a small program that runs in the background on a machine and holds that machine's terminals: the shells, the agents, everything they are running. c11 is the window you look through. Close the window, quit c11 or update it, and the herder core keeps every terminal alive; open c11 again and they are all still there."))
                    paragraph(String(localized: "herderTopography.help.why",
                                     defaultValue: "Because terminals live in herder cores rather than in the window, they do not have to live on this Mac. Link a Mac Studio in the closet, a Mac mini at the office or a friend's spare machine, and its terminals open right here, in the same workspaces, next to your local ones. Heavy builds and long agent runs go where the power is; you stay where you are."))
                    paragraph(String(localized: "herderTopography.help.map",
                                     defaultValue: "The map shows c11 in the middle and every herder core it knows on the ring around it. Green is connected, orange is linked but unreachable right now, gray is a name you saved for a machine that is no longer linked. The gear beside a machine names and colors it, updates its herder core, or removes it."))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "titlebar.herderCores.addTitle", defaultValue: "Add another machine"))
                            .font(.system(size: 13, weight: .semibold))
                        ForEach(Array(HerderCoresPopover.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .frame(width: 12, alignment: .trailing)
                                Text(step)
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    paragraph(String(localized: "herderTopography.help.trust",
                                     defaultValue: "Link only Macs you trust: a program running as you on a linked Mac could act as one of its c11 terminals. Removing a machine ends c11's terminals there and unlinks it."))
                    agentBox
                }
                .padding(.trailing, 6)
            }
            HStack {
                Spacer()
                if let onAddMachine {
                    Button(String(localized: "settings.machines.add", defaultValue: "Add Machine…"), action: onAddMachine)
                        .accessibilityIdentifier("HerderTopographyHelpAdd")
                }
                Button(String(localized: "herderTopography.help.done", defaultValue: "Done"), action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580, height: 640)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var agentBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(String(localized: "herderTopography.help.agentTitle", defaultValue: "Or hand it to your agent"),
                      systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(HerderTopography.agentPrompt, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied
                          ? String(localized: "herderTopography.help.copied", defaultValue: "Copied")
                          : String(localized: "herderTopography.help.copy", defaultValue: "Copy Prompt"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("HerderTopographyCopyPrompt")
            }
            Text(String(localized: "herderTopography.help.agentLede",
                        defaultValue: "Paste this into Claude Code, Codex or any agent running in a c11 terminal. It checks the machine first, shows you the command, and links nothing until you say yes."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(HerderTopography.agentPrompt)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 170)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                    )
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
        )
    }
}

/// C11H-391: what a linked machine's Settings row offers, from the sessions
/// that link its name: c11's own (`own`, the links session while adopted)
/// and c11h's old link (`c11h`).
/// - Only c11h's link: its note and Link Again (Add Machine in c11's own
///   session, prefilled from c11h's entry, consent first).
/// - Both: c11's own link is updated or repaired from its own session, as
///   if it were alone (Astra 3 on #382), and c11h's link is noted and
///   removed on its own, independently, while its agents finish.
/// - Only c11's own: the row as before this ticket.
struct MachineLinkActions: Equatable {
    var note: String?
    var offersUpdate: Bool
    /// The Update button reads "Link Again…".
    var linksAgain: Bool
    /// The session whose listed entry Update or Link Again takes its SSH
    /// target from; nil takes the row's entry.
    var targetSession: String?
    /// Add Machine's `update`: false for Link Again, a first link in c11's session.
    var update: Bool
    /// The session Remove… acts on; nil when the name has one link.
    var removeSession: String?
    /// c11h's link beside c11's own: Remove c11h's Link… acts on it.
    var removeC11hLinkSession: String?

    /// C11H-391: a link c11h made, which c11 won't open terminals through.
    static func c11hLinkNote(beside own: Bool) -> String {
        own
            ? String(localized: "settings.machines.c11hLinkBeside",
                     defaultValue: "c11h's old link of this name is still listed; its terminals keep running. New terminals use c11's link. Remove c11h's link when they have finished.")
            : String(localized: "settings.machines.c11hLinkOnly",
                     defaultValue: "c11h linked this machine; c11 opens no new terminals through that link, and c11h's terminals there keep running. Link it again to open new ones.")
    }

    /// `ownNote` and `ownOffersUpdate`: the row's note and Update rule from
    /// c11's own link (Settings reads c11's own session's entry first).
    static func decide(own: String?, c11h: String?, isLocal: Bool, ownNote: String?, ownOffersUpdate: Bool) -> MachineLinkActions {
        guard !isLocal, let c11h else {
            return MachineLinkActions(note: ownNote, offersUpdate: ownOffersUpdate, linksAgain: false, targetSession: own,
                                      update: true, removeSession: own, removeC11hLinkSession: nil)
        }
        guard let own else {
            return MachineLinkActions(note: c11hLinkNote(beside: false), offersUpdate: true,
                                      linksAgain: true, targetSession: c11h, update: false, removeSession: c11h,
                                      removeC11hLinkSession: nil)
        }
        let beside = c11hLinkNote(beside: true)
        return MachineLinkActions(note: ownNote.map { "\($0) \(beside)" } ?? beside,
                                  offersUpdate: ownNote != nil && ownOffersUpdate, linksAgain: false, targetSession: own,
                                  update: true, removeSession: own, removeC11hLinkSession: c11h)
    }
}
