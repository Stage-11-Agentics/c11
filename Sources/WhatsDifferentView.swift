import AppKit
import SwiftUI

/// C11H-127: the "What's different in c11" sheet. One screen: a picture of
/// this window with lines to the places its terminals run, then four short
/// points. Nothing waits on it: terminals start and run whether it is open,
/// closed or never seen.
struct WhatsDifferentSheet: View {
    @ObservedObject var model: WhatsDifferentModel
    /// C11H-267: a c11 1.x upgrader reads what changed and how to stop it.
    var audience: WhatsDifferentAudience = .standard
    let onDone: () -> Void

    /// The window's title and the Help menu item, by audience.
    static func windowTitle(_ audience: WhatsDifferentAudience) -> String {
        switch audience {
        case .standard:
            return String(localized: "whatsDifferent.windowTitle", defaultValue: "What's Different in c11")
        case .upgradeFrom1x:
            return String(localized: "whatsDifferent.upgrade.windowTitle", defaultValue: "What's New in c11 2.0")
        }
    }

    private var isUpgrade: Bool { audience == .upgradeFrom1x }

    static let width: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 18)
            WhatsDifferentPicture(places: model.places, showsNoMachinesHint: !isUpgrade)
                .padding(.bottom, 22)
            points
                .padding(.bottom, 22)
            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onDone)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: isUpgrade ? "c11 2.0" : "c11")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(WhatsDifferentPalette.gold)
            Text(isUpgrade
                 ? String(localized: "whatsDifferent.upgrade.title",
                          defaultValue: "Quitting c11 no longer ends your terminals.")
                 : String(localized: "whatsDifferent.title",
                          defaultValue: "Your terminals don't live in this window."))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .fixedSize(horizontal: false, vertical: true)
            Text(isUpgrade
                 ? String(localized: "whatsDifferent.upgrade.subtitle",
                          defaultValue: "A background helper called hc now holds them. Your shells, agents and jobs keep running when c11 quits, updates or crashes, and they are there when you open it again.")
                 : String(localized: "whatsDifferent.subtitle",
                          defaultValue: "The window shows them. They run somewhere else: on this Mac, or on another machine you linked."))
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var points: some View {
        if isUpgrade { upgradePoints } else { standardPoints }
    }

    /// C11H-267: what changed since c11 1.x, and how to stop it. No remote
    /// point: a 1.x user starts on this Mac alone.
    private var upgradePoints: some View {
        VStack(alignment: .leading, spacing: 12) {
            WhatsDifferentPoint(
                number: 1,
                lead: String(localized: "whatsDifferent.point.persist.lead", defaultValue: "They keep running."),
                detail: String(localized: "whatsDifferent.upgrade.persist.body",
                             defaultValue: "Quit c11, or let it update or crash, and every terminal carries on. Open c11 again and you are back in the same sessions.")
            )
            WhatsDifferentPoint(
                number: 2,
                lead: String(localized: "whatsDifferent.point.close.lead", defaultValue: "Closing a panel ends it."),
                detail: String(localized: "whatsDifferent.upgrade.close.body",
                             defaultValue: "End Session stops that terminal and everything it started, nohup and background jobs too. In c11 1.x they outlived the panel.")
            )
            WhatsDifferentPoint(
                number: 3,
                lead: String(localized: "whatsDifferent.upgrade.hc.lead", defaultValue: "hc runs in the background."),
                detail: String(localized: "whatsDifferent.upgrade.hc.body",
                             defaultValue: "It holds your terminals while c11 is closed. To see it and every terminal it holds, choose Window > hc Core.")
            )
            WhatsDifferentPoint(number: 4, lead: Self.stopLead, detail: Self.stopDetail(.upgradeFrom1x))
        }
        .accessibilityIdentifier("whatsDifferent.upgradePoints")
    }

    /// C11H-267: how to stop it, in both variants. End All Sessions exists in
    /// every build; the Quit switch is Settings ▸ General ▸ Keep Terminals After Quit.
    private static var stopLead: String {
        String(localized: "whatsDifferent.stop.lead", defaultValue: "To stop it all,")
    }

    private static func stopDetail(_ audience: WhatsDifferentAudience) -> String {
        let endAll = String(localized: "whatsDifferent.stop.body",
                            defaultValue: "choose End All Sessions\u{2026} in the c11 menu. It ends every terminal and the jobs inside them.")
        let quit = audience == .upgradeFrom1x
            ? String(localized: "whatsDifferent.stop.switch.upgrade",
                     defaultValue: "To have Quit end your terminals as c11 1.x did, turn off Keep Terminals After Quit in Settings > General.")
            : String(localized: "whatsDifferent.stop.switch",
                     defaultValue: "To have Quit end your terminals too, turn off Keep Terminals After Quit in Settings > General.")
        return endAll + " " + quit
    }

    private var standardPoints: some View {
        VStack(alignment: .leading, spacing: 12) {
            WhatsDifferentPoint(
                number: 1,
                lead: String(localized: "whatsDifferent.point.persist.lead", defaultValue: "They keep running."),
                detail: String(localized: "whatsDifferent.point.persist.body",
                             defaultValue: "Quit c11, or let it crash or update, and your terminals and agents carry on. Open it again and you are back in the same sessions.")
            )
            WhatsDifferentPoint(
                number: 2,
                lead: String(localized: "whatsDifferent.point.close.lead", defaultValue: "Closing a panel ends it."),
                detail: String(localized: "whatsDifferent.point.close.body",
                             defaultValue: "End Session stops that terminal and everything it started, background jobs too.")
            )
            WhatsDifferentPoint(
                number: 3,
                lead: String(localized: "whatsDifferent.point.remote.lead", defaultValue: "Some can run on another machine."),
                detail: String(localized: "whatsDifferent.point.remote.body",
                             defaultValue: "A terminal on another computer still sits in this window. Open one from the File menu, or with c11 new-panel --on from the command line.")
            )
            WhatsDifferentPoint(
                number: 4,
                lead: String(localized: "whatsDifferent.point.label.lead", defaultValue: "The label says where."),
                detail: String(localized: "whatsDifferent.point.label.body",
                             defaultValue: "Each terminal's title bar names the machine it runs on. \u{201C}not kept\u{201D} means it won't survive a restart. \u{201C}Reconnecting\u{201D} means the link is down; the session itself is fine.")
            )
            WhatsDifferentPoint(number: 5, lead: Self.stopLead, detail: Self.stopDetail(.standard))
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(isUpgrade
                 ? String(localized: "whatsDifferent.upgrade.footer.reopen",
                          defaultValue: "Open this again from Help > What's New in c11 2.0.")
                 : String(localized: "whatsDifferent.footer.reopen",
                          defaultValue: "Open this again from Help > What's Different in c11."))
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(String(localized: "whatsDifferent.done", defaultValue: "Got It"), action: onDone)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                // C11H-166: name it for AX (AXDescription), not only its title.
                .accessibilityLabel(Text(String(localized: "whatsDifferent.done", defaultValue: "Got It")))
                .accessibilityIdentifier("whatsDifferent.done")
        }
    }
}

private struct WhatsDifferentPoint: View {
    let number: Int
    let lead: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(WhatsDifferentPalette.gold)
                .frame(width: 14, alignment: .trailing)
            (Text(lead).fontWeight(.semibold).foregroundColor(Color(nsColor: .labelColor))
                + Text(verbatim: " ")
                + Text(detail).foregroundColor(Color(nsColor: .secondaryLabelColor)))
                .font(.system(size: 13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum WhatsDifferentPalette {
    static let gold = Color(nsColor: BrandColors.gold)

    /// Colors for machines with none set in the roster, in name order. Each
    /// reads on light and dark backgrounds.
    static let remoteDefaults: [NSColor] = [
        NSColor(srgbRed: 0.25, green: 0.65, blue: 0.84, alpha: 1),  // #3FA7D6
        NSColor(srgbRed: 0.42, green: 0.70, blue: 0.47, alpha: 1),  // #6BB378
        NSColor(srgbRed: 0.61, green: 0.48, blue: 0.83, alpha: 1),  // #9B7BD4
        NSColor(srgbRed: 0.85, green: 0.54, blue: 0.37, alpha: 1),  // #D98A5F
    ]

    static func color(for place: WhatsDifferentPlace, remoteIndex: Int) -> Color {
        if let hex = place.colorHex, let color = nsColor(hex: hex) { return Color(nsColor: color) }
        if place.isLocal { return gold }
        return Color(nsColor: remoteDefaults[remoteIndex % remoteDefaults.count])
    }

    static func nsColor(hex raw: String) -> NSColor? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// This window on the left, a line from it to each place its terminals run,
/// and each place with its live terminal count. Geometry is fixed per row so
/// counts changing never move anything.
struct WhatsDifferentPicture: View {
    let places: [WhatsDifferentPlace]
    /// The "no other machine is linked" line under the picture.
    var showsNoMachinesHint = true

    static let rowHeight: CGFloat = 48
    static let windowSize = CGSize(width: 140, height: 94)
    static let lineGap: CGFloat = 58
    static let windowLabelHeight: CGFloat = 14
    static let windowLabelSpacing: CGFloat = 8

    private var drawn: [WhatsDifferentPlace] {
        let remotes = places.filter { !$0.isLocal }
        let local = places.filter(\.isLocal)
        guard remotes.count > WhatsDifferentPlaces.maximumDrawnMachines else { return local + remotes }
        return local + Array(remotes.prefix(WhatsDifferentPlaces.maximumDrawnMachines - 1))
    }

    private var overflow: (machines: Int, terminals: Int)? {
        let remotes = places.filter { !$0.isLocal }
        guard remotes.count > WhatsDifferentPlaces.maximumDrawnMachines else { return nil }
        let rest = remotes.dropFirst(WhatsDifferentPlaces.maximumDrawnMachines - 1)
        return (rest.count, rest.reduce(0) { $0 + $1.terminals })
    }

    private var rowCount: Int { drawn.count + (overflow == nil ? 0 : 1) }
    private var hasRemote: Bool { places.contains { !$0.isLocal } }

    private var height: CGFloat {
        max(Self.windowSize.height + 28, CGFloat(rowCount) * Self.rowHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                lines
                HStack(alignment: .center, spacing: 0) {
                    VStack(spacing: Self.windowLabelSpacing) {
                        WhatsDifferentWindowGlyph()
                            .frame(width: Self.windowSize.width, height: Self.windowSize.height)
                        Text(String(localized: "whatsDifferent.picture.window", defaultValue: "This window"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(height: Self.windowLabelHeight)
                    }
                    .frame(width: Self.windowSize.width)
                    Spacer().frame(width: Self.lineGap)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(drawn.enumerated()), id: \.element.id) { index, place in
                            WhatsDifferentPlaceRow(place: place,
                                                   color: color(at: index))
                                .frame(height: Self.rowHeight)
                        }
                        if let overflow {
                            WhatsDifferentOverflowRow(machines: overflow.machines, terminals: overflow.terminals)
                                .frame(height: Self.rowHeight)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: height)
            }
            .frame(height: height)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("whatsDifferent.picture")

            if showsNoMachinesHint && !hasRemote {
                Text(String(localized: "whatsDifferent.picture.noMachines",
                            defaultValue: "No other machine is linked yet. The c11 install guide shows how to add one."))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func color(at index: Int) -> Color {
        let place = drawn[index]
        let remoteIndex = drawn[..<index].filter { !$0.isLocal }.count
        return WhatsDifferentPalette.color(for: place, remoteIndex: remoteIndex)
    }

    /// One curve per row from the window's right edge to the row's dot.
    private var lines: some View {
        let rows = rowCount
        let height = height
        let colors = (0..<drawn.count).map { color(at: $0) }
        let dashed = drawn.map { $0.link == .reconnecting } + (overflow == nil ? [] : [false])
        let overflowColor = Color(nsColor: .tertiaryLabelColor)
        return Canvas { context, _ in
            // The glyph sits above its one-line label, centred as a group.
            let start = CGPoint(x: Self.windowSize.width + 2,
                                y: height / 2 - (Self.windowLabelSpacing + Self.windowLabelHeight) / 2)
            let rowsTop = (height - CGFloat(rows) * Self.rowHeight) / 2
            for row in 0..<rows {
                let end = CGPoint(x: Self.windowSize.width + Self.lineGap + 5,
                                  y: rowsTop + CGFloat(row) * Self.rowHeight + Self.rowHeight / 2)
                var path = Path()
                path.move(to: start)
                let bend = Self.lineGap * 0.55
                path.addCurve(to: end,
                              control1: CGPoint(x: start.x + bend, y: start.y),
                              control2: CGPoint(x: end.x - bend, y: end.y))
                let color = row < colors.count ? colors[row] : overflowColor
                let style = StrokeStyle(lineWidth: 1.6, lineCap: .round,
                                        dash: dashed[row] ? [3, 4] : [])
                context.stroke(path, with: .color(color.opacity(0.85)), style: style)
            }
            var origin = Path()
            origin.addEllipse(in: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6))
            context.fill(origin, with: .color(Color(nsColor: .secondaryLabelColor)))
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WhatsDifferentPlaceRow: View {
    let place: WhatsDifferentPlace
    let color: Color

    private var detail: String {
        switch place.link {
        case .local:
            return String(localized: "whatsDifferent.place.local", defaultValue: "This Mac")
        case .connected:
            return String(localized: "whatsDifferent.place.connected", defaultValue: "Linked machine")
        case .reconnecting:
            return String(localized: "whatsDifferent.place.reconnecting", defaultValue: "Reconnecting")
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: place.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(place.link == .reconnecting
                                     ? Color(nsColor: .systemOrange)
                                     : Color(nsColor: .secondaryLabelColor))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            WhatsDifferentCount(value: place.terminals)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("whatsDifferent.place.\(place.id)")
    }
}

private struct WhatsDifferentOverflowRow: View {
    let machines: Int
    let terminals: Int

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1.5)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "whatsDifferent.place.more", defaultValue: "Other machines"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                Text(String(format: String(localized: "whatsDifferent.place.moreCount",
                                           defaultValue: "Machines: %lld"), Int64(machines)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            Spacer(minLength: 8)
            WhatsDifferentCount(value: terminals)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A stat tile: the number large, its noun small under it. Fixed width, so a
/// count going from 9 to 10 moves nothing.
private struct WhatsDifferentCount: View {
    let value: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(verbatim: "\(value)")
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color(nsColor: value > 0 ? .labelColor : .tertiaryLabelColor))
            Text(String(localized: "whatsDifferent.place.terminals", defaultValue: "terminals"))
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
        }
        .frame(width: 64, alignment: .trailing)
    }
}

/// A small drawing of a c11 window: title bar, sidebar, and three panels.
private struct WhatsDifferentWindowGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = Color(nsColor: .separatorColor)
            let fill = Color(nsColor: .windowBackgroundColor)
            let cell = Color(nsColor: .labelColor).opacity(0.07)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fill)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(frame, lineWidth: 1)
                HStack(spacing: 3) {
                    ForEach([Color.red, Color.yellow, Color.green], id: \.self) { dot in
                        Circle().fill(dot.opacity(0.75)).frame(width: 5, height: 5)
                    }
                }
                .offset(x: 7, y: 6)
                // Sidebar with two workspace cards; the first is selected.
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(WhatsDifferentPalette.gold.opacity(0.55))
                        .frame(height: 9)
                    RoundedRectangle(cornerRadius: 2).fill(cell).frame(height: 9)
                    RoundedRectangle(cornerRadius: 2).fill(cell).frame(height: 9)
                    Spacer(minLength: 0)
                }
                .frame(width: size.width * 0.22, height: size.height - 26)
                .offset(x: 6, y: 18)
                // Three panels: one tall on the left, two stacked on the right.
                let left = size.width * 0.22 + 10
                let panelsWidth = size.width - left - 6
                let panelsHeight = size.height - 24
                HStack(spacing: 3) {
                    terminal(cell)
                        .frame(width: panelsWidth * 0.5 - 1.5)
                    VStack(spacing: 3) {
                        terminal(cell)
                        terminal(cell)
                    }
                }
                .frame(width: panelsWidth, height: panelsHeight)
                .offset(x: left, y: 18)
            }
        }
        .accessibilityHidden(true)
    }

    private func terminal(_ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(fill)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Capsule().fill(Color(nsColor: .labelColor).opacity(0.22)).frame(width: 14, height: 2)
                    Capsule().fill(Color(nsColor: .labelColor).opacity(0.14)).frame(width: 22, height: 2)
                }
                .padding(4)
            }
    }
}
