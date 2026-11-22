import AppKit
import SwiftUI

/// C11H-127, C11H-335: the "What's New in c11 2.0" sheet. One short page per
/// concept, each with a picture and a few numbered points: terminals that
/// outlive the app, terminals on other machines, agent mail. A profile c11
/// took over from the earlier app reads one page of what changed. Nothing
/// waits on it: terminals start and run whether it is open, closed or never
/// seen.
struct WhatsDifferentSheet: View {
    @ObservedObject var model: WhatsDifferentModel
    var audience: WhatsDifferentAudience = .standard
    /// Window ▸ hc Core. Nil hides the page's link.
    var onOpenCore: (() -> Void)? = nil
    /// Settings ▸ Herder Topography, where Add Machine and Link Again live.
    var onOpenMachines: (() -> Void)? = nil
    let onDone: () -> Void
    /// `.key` only while the sheet's own window is key.
    @Environment(\.controlActiveState) private var controlActiveState

    /// The window's title and the Help menu item: the same for every variant.
    static func windowTitle(_ audience: WhatsDifferentAudience) -> String {
        String(localized: "whatsDifferent.upgrade.windowTitle", defaultValue: "What's New in c11 2.0")
    }

    static let width: CGFloat = WhatsDifferentFit.sheetWidth
    /// The sheet's window (AppDelegate.presentWhatsDifferent).
    static let windowIdentifier = NSUserInterfaceItemIdentifier("c11.whatsDifferent")

    private var pages: [WhatsDifferentPage] { WhatsDifferent.pages(for: audience) }
    private var index: Int { min(model.page, pages.count - 1) }
    private var isLast: Bool { index >= pages.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Every page is laid out at once and only the current one shows,
            // so the tallest sets the sheet's height and paging moves nothing.
            ZStack(alignment: .topLeading) {
                ForEach(Array(pages.enumerated()), id: \.element) { position, page in
                    pageView(page, position: position)
                        .opacity(position == index ? 1 : 0)
                        .allowsHitTesting(position == index)
                        .accessibilityHidden(position != index)
                        // Out of the Tab loop too: a hidden page's link never takes focus.
                        .disabled(position != index)
                }
            }
            Divider()
                .padding(.top, 18)
                .padding(.bottom, 14)
            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onDone)
    }

    // MARK: One page

    private func pageView(_ page: WhatsDifferentPage, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow(isNew: page == .machines && audience == .upgradeFrom1x, position: position)
                .padding(.bottom, 6)
            Text(Self.title(page, audience))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            Text(Self.subtitle(page, audience))
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            picture(page)
                .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Self.points(page, audience).enumerated()), id: \.offset) { offset, point in
                    WhatsDifferentPoint(number: offset + 1, lead: point.lead, detail: point.detail)
                }
            }
            .padding(.bottom, 16)
            linkRow(page)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("whatsDifferent.page.\(page.rawValue)")
    }

    private func eyebrow(isNew: Bool, position: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "c11 2.0")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(WhatsDifferentPalette.gold)
            if isNew {
                Text(String(localized: "whatsDifferent.new", defaultValue: "NEW"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(WhatsDifferentPalette.gold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(WhatsDifferentPalette.gold.opacity(0.7), lineWidth: 1))
            }
            Spacer(minLength: 8)
            if pages.count > 1 {
                Text(verbatim: "\(position + 1) / \(pages.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .accessibilityLabel(Text(String(format: String(localized: "whatsDifferent.pageCount",
                                                                   defaultValue: "Page %lld of %lld"),
                                                    Int64(position + 1), Int64(pages.count))))
            }
        }
    }

    @ViewBuilder
    private func picture(_ page: WhatsDifferentPage) -> some View {
        switch page {
        case .terminals:
            WhatsDifferentTerminalsPicture(terminals: model.places.first(where: \.isLocal)?.terminals ?? 0)
        case .machines:
            WhatsDifferentPicture(places: model.places, showsNoMachinesHint: false)
        case .mail:
            WhatsDifferentMailPicture()
        case .adopted:
            WhatsDifferentAdoptedPicture()
        }
    }

    private func linkRow(_ page: WhatsDifferentPage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let link = link(page) {
                Button(link.title, action: link.action)
                    .buttonStyle(.link)
                    .font(.system(size: 13))
                    .accessibilityIdentifier("whatsDifferent.link.\(page.rawValue)")
            }
            Spacer(minLength: 8)
            Text(String(localized: "whatsDifferent.upgrade.footer.reopen",
                        defaultValue: "Open this again from Help > What's New in c11 2.0."))
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func link(_ page: WhatsDifferentPage) -> (title: String, action: () -> Void)? {
        switch page {
        case .terminals:
            guard let onOpenCore else { return nil }
            return (String(localized: "whatsDifferent.link.core", defaultValue: "Open hc Core"), onOpenCore)
        case .machines, .adopted:
            guard let onOpenMachines else { return nil }
            return (String(localized: "whatsDifferent.link.machines", defaultValue: "Open Herder Topography"), onOpenMachines)
        case .mail:
            return nil
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            if pages.count > 1 {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { position in
                        Circle()
                            .fill(position == index ? WhatsDifferentPalette.gold : Color(nsColor: .tertiaryLabelColor))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
            }
            Spacer(minLength: 8)
            // One page needs only Got It; Esc still closes.
            if pages.count > 1 {
                let close = String(localized: "whatsDifferent.close", defaultValue: "Close")
                let back = String(localized: "whatsDifferent.back", defaultValue: "Back")
                Button {
                    if index == 0 { onDone() } else { model.page = index - 1 }
                } label: {
                    Self.twin(close, back, showsFirst: index == 0)
                }
                .controlSize(.large)
                .accessibilityLabel(Text(index == 0 ? close : back))
                .accessibilityIdentifier(index == 0 ? "whatsDifferent.close" : "whatsDifferent.back")
            }
            let next = String(localized: "whatsDifferent.next", defaultValue: "Next")
            let done = String(localized: "whatsDifferent.done", defaultValue: "Got It")
            Button {
                if isLast { onDone() } else { model.page = index + 1 }
            } label: {
                Self.twin(next, done, showsFirst: !isLast)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            // C11H-166: name it for AX (AXDescription), not only its title.
            .accessibilityLabel(Text(isLast ? done : next))
            .accessibilityIdentifier(isLast ? "whatsDifferent.done" : "whatsDifferent.next")
        }
        .background {
            // Esc closes from any page. `onExitCommand` needs a focused view,
            // and the sheet usually has none, so a key equivalent does it. It
            // sits behind the footer, so it moves nothing, and out of the focus
            // loop, so Full Keyboard Access's Space never presses it.
            Button(action: escape) { Text(verbatim: "") }
                .keyboardShortcut(.cancelAction)
                // Off while another window is key, so Esc stays that window's.
                .disabled(controlActiveState != .key)
                .focusable(false)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// AppKit offers a key equivalent the key window leaves to the main window
    /// too, so Esc pressed in a panel such as Panel Details, with this sheet
    /// main behind it, would reach this button. It closes the sheet only when
    /// the sheet itself is key.
    private func escape() {
        guard NSApp.keyWindow?.identifier == Self.windowIdentifier else { return }
        onDone()
    }

    /// Both of a button's labels laid out and only one shown, so the button
    /// is as wide as the wider in every language and nothing beside it moves
    /// when its label changes.
    private static func twin(_ first: String, _ second: String, showsFirst: Bool) -> some View {
        ZStack {
            Text(first).opacity(showsFirst ? 1 : 0)
            Text(second).opacity(showsFirst ? 0 : 1)
        }
    }

    // MARK: Copy

    struct Point {
        let lead: String
        let detail: AttributedString
    }

    /// Inline Markdown, so a command in backticks reads as code in every
    /// language; translations keep the backticked text as it is.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private static var legacyName: String { C11Identity.Legacy.appName }

    static func title(_ page: WhatsDifferentPage, _ audience: WhatsDifferentAudience) -> String {
        switch page {
        case .terminals:
            return audience == .upgradeFrom1x
                ? String(localized: "whatsDifferent.upgrade.title", defaultValue: "Quitting c11 no longer ends your terminals.")
                : String(localized: "whatsDifferent.title", defaultValue: "Your terminals don't live in this window.")
        case .machines:
            return String(localized: "whatsDifferent.machines.title", defaultValue: "Your terminals can run on other machines.")
        case .mail:
            return String(localized: "whatsDifferent.mail.title", defaultValue: "Agents send each other mail.")
        case .adopted:
            return String(format: String(localized: "whatsDifferent.adopted.title", defaultValue: "%@ is now c11 2.0."), legacyName)
        }
    }

    static func subtitle(_ page: WhatsDifferentPage, _ audience: WhatsDifferentAudience) -> String {
        switch page {
        case .terminals:
            return audience == .upgradeFrom1x
                ? String(localized: "whatsDifferent.upgrade.subtitle",
                         defaultValue: "A background helper called hc now holds them. Your shells, agents and jobs keep running when c11 quits, updates or crashes, and they are there when you open it again.")
                : String(localized: "whatsDifferent.terminals.subtitle",
                         defaultValue: "The window shows them. A helper called hc holds them, so they keep running when c11 quits, updates or crashes.")
        case .machines:
            return String(localized: "whatsDifferent.machines.subtitle",
                          defaultValue: "Link a Mac or an x86-64 Linux machine you reach over SSH, and its terminals sit in this window beside the ones on this Mac.")
        case .mail:
            return String(localized: "whatsDifferent.mail.subtitle",
                          defaultValue: "Every panel has a mailbox. Agents hand off work, report back and ask questions without typing into each other's terminals.")
        case .adopted:
            return String(format: String(localized: "whatsDifferent.adopted.subtitle",
                                         defaultValue: "c11 quit %@ and took over its terminals on this Mac. Your workspaces and settings came across, and the terminals kept running."),
                          legacyName)
        }
    }

    static func points(_ page: WhatsDifferentPage, _ audience: WhatsDifferentAudience) -> [Point] {
        switch page {
        case .terminals:
            let upgrade = audience == .upgradeFrom1x
            return [
                Point(lead: String(localized: "whatsDifferent.point.persist.lead", defaultValue: "They keep running."),
                      detail: inline(upgrade
                          ? String(localized: "whatsDifferent.upgrade.persist.reboot.body",
                                   defaultValue: "Quit c11, or let it update or crash, and every terminal carries on. A reboot still ends them; each saved agent conversation then resumes once.")
                          : String(localized: "whatsDifferent.point.persist.reboot.body",
                                   defaultValue: "Quit c11, or let it crash or update, and your terminals and agents carry on. A reboot still ends them; each saved agent conversation then resumes once."))),
                Point(lead: String(localized: "whatsDifferent.point.close.lead", defaultValue: "Closing a panel ends it."),
                      detail: inline(upgrade
                          ? String(localized: "whatsDifferent.upgrade.close.body",
                                   defaultValue: "End Session stops that terminal and everything it started, nohup and background jobs too. In c11 1.x they outlived the panel.")
                          : String(localized: "whatsDifferent.point.close.body",
                                   defaultValue: "End Session stops that terminal and everything it started, background jobs too."))),
                Point(lead: String(localized: "whatsDifferent.upgrade.hc.lead", defaultValue: "hc runs in the background."),
                      detail: inline(String(localized: "whatsDifferent.upgrade.hc.body",
                                            defaultValue: "It holds your terminals while c11 is closed. To see it and every terminal it holds, choose Window > hc Core."))),
                Point(lead: stopLead, detail: inline(stopDetail(audience))),
            ]
        case .machines:
            return [
                Point(lead: String(localized: "whatsDifferent.machines.link.lead", defaultValue: "Link one."),
                      detail: inline(String(localized: "whatsDifferent.machines.link.body",
                                            defaultValue: "Settings > Herder Topography > Add Machine\u{2026}, or `c11 machine link --host <ssh-target>`. c11 installs its own hc there."))),
                Point(lead: String(localized: "whatsDifferent.machines.where.lead", defaultValue: "Choose where."),
                      detail: inline(String(localized: "whatsDifferent.machines.where.body",
                                            defaultValue: "New Terminal and agent launches ask where to run. From the command line, add `--on <machine>`."))),
                Point(lead: String(localized: "whatsDifferent.point.label.lead", defaultValue: "The label says where."),
                      detail: inline(String(localized: "whatsDifferent.machines.label.body",
                                            defaultValue: "Each terminal's title bar names its machine, in a color you choose. Reconnecting means the link is down; the session itself is fine."))),
                Point(lead: String(localized: "whatsDifferent.machines.agents.lead", defaultValue: "Agents there work as local ones."),
                      detail: inline(String(localized: "whatsDifferent.machines.agents.body",
                                            defaultValue: "They set their status, raise flags and send mail. Link only machines you trust: linking gives c11 a shell there as you."))),
            ]
        case .mail:
            return [
                Point(lead: String(localized: "whatsDifferent.mail.cell.lead", defaultValue: "Every panel has one."),
                      detail: inline(String(localized: "whatsDifferent.mail.cell.body",
                                            defaultValue: "The mailbox cell under each terminal opens its thread."))),
                Point(lead: String(localized: "whatsDifferent.mail.address.lead", defaultValue: "Address an agent."),
                      detail: inline(String(localized: "whatsDifferent.mail.address.body",
                                            defaultValue: "`c11 mailbox send --to <address>`, or `--to-parent` for the agent that launched it. Agents on linked machines send the same way."))),
                Point(lead: String(localized: "whatsDifferent.mail.wait.lead", defaultValue: "Mail waits for a free moment."),
                      detail: inline(String(localized: "whatsDifferent.mail.wait.body",
                                            defaultValue: "It arrives when the agent is idle, never mid-turn, and survives a relaunch. `c11 mailbox status <id>` says where a message is and why."))),
                Point(lead: String(localized: "whatsDifferent.mail.web.lead", defaultValue: "See who talks to whom."),
                      detail: inline(String(localized: "whatsDifferent.mail.web.body",
                                            defaultValue: "`c11 messages view` draws every conversation as a web."))),
            ]
        case .adopted:
            return [
                Point(lead: String(localized: "whatsDifferent.adopted.sessions.lead", defaultValue: "Same sessions."),
                      detail: inline(String(format: String(localized: "whatsDifferent.adopted.sessions.body",
                                                           defaultValue: "Terminals on this Mac kept running, and c11 attached to them. Keep %@.app installed for now: they still use its helper."),
                                            legacyName))),
                Point(lead: String(localized: "whatsDifferent.adopted.relink.lead", defaultValue: "Link each machine again."),
                      detail: inline(String(format: String(localized: "whatsDifferent.adopted.relink.body",
                                                           defaultValue: "Settings > Herder Topography > Link Again\u{2026} puts a machine %1$@ linked on c11's own link beside %1$@'s, so new terminals and mail work there at once. Terminals %1$@ opened there keep running."),
                                            legacyName))),
                Point(lead: String(localized: "whatsDifferent.adopted.name.lead", defaultValue: "One name."),
                      detail: inline(String(format: String(localized: "whatsDifferent.adopted.name.body",
                                                           defaultValue: "The app, the `c11` command and the `C11_` variables use c11's names, and updates come from c11's feed. The %@ names still work."),
                                            legacyName))),
            ]
        }
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
}

private struct WhatsDifferentPoint: View {
    let number: Int
    let lead: String
    let detail: AttributedString

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

// MARK: Pictures

/// C11H-335: the sizes the pictures are drawn at, and every label they set in
/// a box of fixed size. The pictures take their geometry from here, and
/// `WhatsDifferentTests` lays out each label's translation in every language
/// at the same font and width, so a box that shrinks or a translation that
/// grows fails a test instead of clipping on screen.
enum WhatsDifferentFit {
    static let sheetWidth: CGFloat = 600
    /// The window glyph every picture starts from, and the gap after it.
    static let windowGlyph = CGSize(width: 140, height: 94)
    static let lineGap: CGFloat = 58
    /// A picture's inside: the sheet's content width less the frame's padding.
    static let pictureWidth: CGFloat = sheetWidth - 2 * 28 - 2 * 14
    static let pictureHeight: CGFloat = windowGlyph.height + 28

    /// The stat tile (WhatsDifferentCount) beside the terminals and machines labels.
    static let countTileWidth: CGFloat = 64

    // The terminals picture: the window glyph, the gap, then hc's box.
    static let hcBoxInset: CGFloat = 12
    static let hcBoxInnerWidth: CGFloat = pictureWidth - windowGlyph.width - lineGap - 2 * hcBoxInset
    /// The box's top row: two caps labels with a Spacer between them, the
    /// stack's spacing on each side of it, so together they have this much.
    static let hcCapsSpacing: CGFloat = 8
    static let hcCapsPairWidth: CGFloat = hcBoxInnerWidth - 2 * hcCapsSpacing
    /// The box's second row: three dots, the label and the count tile.
    static let hcDotSize: CGFloat = 7
    static let hcRowSpacing: CGFloat = 10
    static let hcKeptWidth: CGFloat = hcBoxInnerWidth - hcDotSize - 2 * hcRowSpacing - countTileWidth

    // The mail picture: three cards and the two gaps between them.
    static let mailGap: CGFloat = 36
    static let mailCardWidth: CGFloat = (pictureWidth - 2 * mailGap) / 3
    static let mailCardHeight: CGFloat = 92
    static let mailCardInset: CGFloat = 10
    static let mailTextWidth: CGFloat = mailCardWidth - 2 * mailCardInset
    static let mailNoteLines = 2
    /// The card's foot: the Mailbox caption, a Spacer, the `✉ n` tile, the
    /// stack's spacing on each side of the Spacer.
    static let mailCaptionSpacing: CGFloat = 4
    static let mailCountWidth: CGFloat = 21
    static let mailCountFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    /// The envelope in text presentation, so no font fallback draws it as the
    /// wider color emoji.
    static let mailCountGlyph = "\u{2709}\u{FE0E}"

    // The adoption picture.
    static let appBoxSize = CGSize(width: 132, height: 70)
    static let appBoxInset: CGFloat = 6
    static let adoptedNoteWidth: CGFloat = 132

    // The machines picture's rows (WhatsDifferentPlaceRow): the dot, the
    // labels, a Spacer and the count tile, the stack's spacing between each.
    static let placeRowWidth: CGFloat = pictureWidth - windowGlyph.width - lineGap
    static let placeDotSize: CGFloat = 10
    static let placeRowSpacing: CGFloat = 10
    static let placeSpacerMinimum: CGFloat = 8
    static let placeDetailWidth: CGFloat = placeRowWidth - placeDotSize - 3 * placeRowSpacing - placeSpacerMinimum - countTileWidth

    struct Label {
        let key: String
        let font: NSFont
        var kern: CGFloat = 0
        var uppercased = false
        let width: CGFloat
        let lines: Int
    }

    /// Two labels that share one row: together they fit `width`.
    struct Pair {
        let first: Label
        let second: Label
        let width: CGFloat
    }

    static let capsFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
    static let capsKern: CGFloat = 0.8
    /// Each label is measured this much narrower than its box, for the small
    /// differences between this layout and SwiftUI's.
    static let allowance: CGFloat = 2

    /// Every label drawn in a box of fixed size. Free text (titles, points,
    /// buttons) wraps or sizes itself and is not listed.
    static let labels: [Label] = [
        Label(key: "whatsDifferent.picture.quits", font: .systemFont(ofSize: 11, weight: .medium),
              width: windowGlyph.width, lines: 1),
        Label(key: "whatsDifferent.picture.kept", font: .systemFont(ofSize: 12), width: hcKeptWidth, lines: 2),
        Label(key: "whatsDifferent.picture.held", font: .systemFont(ofSize: 10.5), width: mailTextWidth,
              lines: mailNoteLines),
        Label(key: "whatsDifferent.picture.mailbox", font: capsFont, kern: capsKern, uppercased: true,
              width: mailTextWidth - mailCountWidth - 2 * mailCaptionSpacing, lines: 1),
        Label(key: "whatsDifferent.picture.sameSessions", font: capsFont, kern: capsKern, uppercased: true,
              width: appBoxSize.width - 2 * appBoxInset, lines: 1),
        Label(key: "whatsDifferent.picture.stillAttached", font: .systemFont(ofSize: 12),
              width: adoptedNoteWidth, lines: 2),
        Label(key: "whatsDifferent.picture.window", font: .systemFont(ofSize: 11, weight: .medium),
              width: windowGlyph.width, lines: 1),
        Label(key: "whatsDifferent.place.local", font: .systemFont(ofSize: 11), width: placeDetailWidth, lines: 2),
        Label(key: "whatsDifferent.place.connected", font: .systemFont(ofSize: 11), width: placeDetailWidth, lines: 2),
        Label(key: "whatsDifferent.place.reconnecting", font: .systemFont(ofSize: 11), width: placeDetailWidth, lines: 2),
        Label(key: "whatsDifferent.place.more", font: .systemFont(ofSize: 13, weight: .semibold),
              width: placeDetailWidth, lines: 1),
        Label(key: "whatsDifferent.place.terminals", font: .systemFont(ofSize: 10), width: countTileWidth, lines: 1),
    ]

    static let pairs: [Pair] = [
        Pair(first: Label(key: "whatsDifferent.picture.hcHere", font: capsFont, kern: capsKern, uppercased: true,
                          width: hcCapsPairWidth, lines: 1),
             second: Label(key: "whatsDifferent.picture.stillRunning", font: capsFont, kern: capsKern, uppercased: true,
                           width: hcCapsPairWidth, lines: 1),
             width: hcCapsPairWidth),
    ]

    /// Labels set as typed in every language, each with its widest text.
    static let verbatim: [(text: String, label: Label)] = [
        ("\(mailCountGlyph) 2", Label(key: "mail count", font: mailCountFont, width: mailCountWidth, lines: 1)),
    ]

    /// The lines `text` takes when set as `label`, word-wrapped, `allowance`
    /// narrower than the box.
    static func lines(_ text: String, as label: Label, locale: Locale) -> Int {
        let shown = label.uppercased ? text.uppercased(with: locale) : text
        let storage = NSTextStorage(string: shown, attributes: [.font: label.font, .kern: label.kern])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: label.width - allowance, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var lines = 0
        var index = 0
        while index < layout.numberOfGlyphs {
            var range = NSRange()
            layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            lines += 1
            index = max(NSMaxRange(range), index + 1)
        }
        return max(lines, 1)
    }

    /// The width `text` takes on one line when set as `label`, plus `allowance`.
    static func width(_ text: String, as label: Label, locale: Locale) -> CGFloat {
        let shown = label.uppercased ? text.uppercased(with: locale) : text
        return NSAttributedString(string: shown, attributes: [.font: label.font, .kern: label.kern]).size().width + allowance
    }
}

/// The frame every page's picture sits in, the same as the machines picture's.
private struct WhatsDifferentPictureFrame<Content: View>: View {
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: WhatsDifferentFit.pictureWidth, height: WhatsDifferentFit.pictureHeight)
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
            .accessibilityIdentifier(identifier)
    }
}

private struct WhatsDifferentCaps: View {
    let text: String
    var color = Color(nsColor: .secondaryLabelColor)

    var body: some View {
        Text(text.uppercased())
            .font(Font(WhatsDifferentFit.capsFont as CTFont))
            .tracking(WhatsDifferentFit.capsKern)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// c11 quits; hc on this Mac keeps the terminals running, with this Mac's
/// live terminal count.
private struct WhatsDifferentTerminalsPicture: View {
    let terminals: Int

    var body: some View {
        WhatsDifferentPictureFrame(identifier: "whatsDifferent.picture.terminals") {
            HStack(alignment: .center, spacing: 0) {
                VStack(spacing: WhatsDifferentPicture.windowLabelSpacing) {
                    WhatsDifferentWindowGlyph()
                        .frame(width: WhatsDifferentPicture.windowSize.width, height: WhatsDifferentPicture.windowSize.height)
                        .opacity(0.5)
                    Text(String(localized: "whatsDifferent.picture.quits", defaultValue: "c11 quits"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                        .frame(height: WhatsDifferentPicture.windowLabelHeight)
                }
                .frame(width: WhatsDifferentPicture.windowSize.width)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .frame(width: WhatsDifferentPicture.lineGap)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: WhatsDifferentFit.hcCapsSpacing) {
                        WhatsDifferentCaps(text: String(localized: "whatsDifferent.picture.hcHere", defaultValue: "hc on this Mac"))
                        Spacer(minLength: 0)
                        WhatsDifferentCaps(text: String(localized: "whatsDifferent.picture.stillRunning", defaultValue: "Still running"),
                                           color: WhatsDifferentPalette.gold)
                    }
                    HStack(alignment: .center, spacing: WhatsDifferentFit.hcRowSpacing) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle().fill(WhatsDifferentPalette.gold)
                                    .frame(width: WhatsDifferentFit.hcDotSize, height: WhatsDifferentFit.hcDotSize)
                            }
                        }
                        .accessibilityHidden(true)
                        Text(String(localized: "whatsDifferent.picture.kept", defaultValue: "Shells, agents and jobs"))
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: WhatsDifferentFit.hcKeptWidth, alignment: .leading)
                        WhatsDifferentCount(value: terminals)
                    }
                }
                .padding(WhatsDifferentFit.hcBoxInset)
                .frame(width: WhatsDifferentFit.hcBoxInnerWidth + 2 * WhatsDifferentFit.hcBoxInset)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            }
        }
    }
}

/// Three panels mail each other; the third is busy, so its mail waits.
private struct WhatsDifferentMailPicture: View {
    var body: some View {
        WhatsDifferentPictureFrame(identifier: "whatsDifferent.picture.mail") {
            HStack(alignment: .top, spacing: 0) {
                // Panel names are mailbox addresses, so they stay as typed in
                // every language, matching the flags under them.
                panel("planner", mail: 1, flag: "--to builder")
                envelope
                panel("builder", mail: 0, flag: "--to reviewer")
                envelope
                panel("reviewer", mail: 2, flag: "--to-parent",
                      note: String(localized: "whatsDifferent.picture.held", defaultValue: "Busy: held until its turn ends"))
            }
        }
    }

    private var envelope: some View {
        VStack(spacing: 4) {
            Image(systemName: "envelope")
                .font(.system(size: 12))
                .foregroundStyle(WhatsDifferentPalette.gold)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .frame(width: WhatsDifferentFit.mailGap)
        .padding(.top, 26)
        .accessibilityHidden(true)
    }

    private func panel(_ name: String, mail: Int, flag: String, note: String? = nil) -> some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .padding(.top, 9)
                if let note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(WhatsDifferentFit.mailNoteLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                Spacer(minLength: 4)
                HStack(spacing: WhatsDifferentFit.mailCaptionSpacing) {
                    WhatsDifferentCaps(text: String(localized: "whatsDifferent.picture.mailbox", defaultValue: "Mailbox"),
                                       color: Color(nsColor: .tertiaryLabelColor))
                    Spacer(minLength: 0)
                    Text(verbatim: "\(WhatsDifferentFit.mailCountGlyph) \(mail)")
                        .font(Font(WhatsDifferentFit.mailCountFont as CTFont))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                        .frame(width: WhatsDifferentFit.mailCountWidth, alignment: .trailing)
                }
                .padding(.vertical, 5)
                .overlay(alignment: .top) { Divider().padding(.horizontal, -WhatsDifferentFit.mailCardInset) }
            }
            .padding(.horizontal, WhatsDifferentFit.mailCardInset)
            .frame(width: WhatsDifferentFit.mailCardWidth, height: WhatsDifferentFit.mailCardHeight, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            Text(verbatim: flag)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
        }
        .frame(width: WhatsDifferentFit.mailCardWidth)
    }
}

/// The earlier app becomes c11 2.0; the same terminals stay attached.
private struct WhatsDifferentAdoptedPicture: View {
    var body: some View {
        WhatsDifferentPictureFrame(identifier: "whatsDifferent.picture.adopted") {
            HStack(spacing: 18) {
                appBox(C11Identity.Legacy.appName, caption: nil, highlighted: false)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .accessibilityHidden(true)
                appBox("c11 2.0",
                       caption: String(localized: "whatsDifferent.picture.sameSessions", defaultValue: "Same sessions"),
                       highlighted: true)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(WhatsDifferentPalette.gold).frame(width: 7, height: 7)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(String(localized: "whatsDifferent.picture.stillAttached", defaultValue: "Still attached"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: WhatsDifferentFit.adoptedNoteWidth, alignment: .leading)
                }
            }
        }
    }

    private func appBox(_ name: String, caption: String?, highlighted: Bool) -> some View {
        VStack(spacing: 6) {
            Text(verbatim: name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
            if let caption {
                WhatsDifferentCaps(text: caption, color: WhatsDifferentPalette.gold)
            }
        }
        .padding(.horizontal, WhatsDifferentFit.appBoxInset)
        .frame(width: WhatsDifferentFit.appBoxSize.width, height: WhatsDifferentFit.appBoxSize.height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(highlighted ? WhatsDifferentPalette.gold : Color(nsColor: .separatorColor), lineWidth: highlighted ? 1.5 : 1))
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
    static let windowSize = WhatsDifferentFit.windowGlyph
    static let lineGap: CGFloat = WhatsDifferentFit.lineGap
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
        HStack(alignment: .center, spacing: WhatsDifferentFit.placeRowSpacing) {
            Circle()
                .fill(color)
                .frame(width: WhatsDifferentFit.placeDotSize, height: WhatsDifferentFit.placeDotSize)
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
            Spacer(minLength: WhatsDifferentFit.placeSpacerMinimum)
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
        HStack(alignment: .center, spacing: WhatsDifferentFit.placeRowSpacing) {
            Circle()
                .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1.5)
                .frame(width: WhatsDifferentFit.placeDotSize, height: WhatsDifferentFit.placeDotSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "whatsDifferent.place.more", defaultValue: "Other machines"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                Text(String(format: String(localized: "whatsDifferent.place.moreCount",
                                           defaultValue: "Machines: %lld"), Int64(machines)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            Spacer(minLength: WhatsDifferentFit.placeSpacerMinimum)
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
        .frame(width: WhatsDifferentFit.countTileWidth, alignment: .trailing)
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
