import SwiftUI

/// C11H-126 part 2: the Settings sheets for Add Machine (and Update) and Remove Machine.
///
/// C11H-332: Add asks for consent first. Pressing Add on a new machine shows
/// "Link <host> to c11?", which says linking gives c11 a shell there as the
/// operator and links to the trust page (`c11 guide trust`); only "Link
/// <host>" starts. Shown only from an operator's click in Settings ▸ Herder
/// Topography: no socket command opens it, and it is a SwiftUI sheet, never
/// `runModal`. Update (an already linked machine) skips it.

struct AddMachineRequest: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let name: String?
    let update: Bool
}

struct RemoveMachineRequest: Identifiable, Equatable {
    let id = UUID()
    /// hc's machine name.
    let machine: String
    /// What the operator calls it (roster name or default).
    let name: String
    /// C11H-391: whose link to remove, when c11 and c11h both link the name.
    var session: String? = nil
}

struct AddMachineSheet: View {
    let request: AddMachineRequest
    let onClose: () -> Void

    @StateObject private var model = MachineSetupModel()
    @State private var host: String
    @State private var name: String
    /// C11H-332: the consent page is showing.
    @State private var consenting = false
    @State private var showingTrust = false

    /// Body height both pages share, so switching never moves the buttons.
    private static let bodyHeight: CGFloat = 330

    init(request: AddMachineRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _host = State(initialValue: request.host)
        _name = State(initialValue: request.name ?? "")
    }

    private var title: String {
        request.update
            ? String(format: String(localized: "machineSetup.updateTitle", defaultValue: "Update %@"), request.name ?? "")
            : String(localized: "machineSetup.addTitle", defaultValue: "Add Machine")
    }

    private var canStart: Bool {
        !model.running && model.result == nil && HCMachineSetup.isValidHost(host.trimmingCharacters(in: .whitespaces))
    }

    /// The machine as the consent names it: the host without its user.
    private var consentHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        return trimmed.split(separator: "@").last.map(String.init) ?? trimmed
    }

    var body: some View {
        Group {
            if consenting { consentPage } else { formPage }
        }
        .padding(20)
        .frame(width: 480)
        .sheet(isPresented: $showingTrust) { TrustPageSheet { showingTrust = false } }
    }

    private var consentPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: String(localized: "machineSetup.consent.title", defaultValue: "Link %@ to c11?"), consentHost))
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            VStack(alignment: .leading, spacing: 10) {
                Text(String(format: String(localized: "machineSetup.consent.headline",
                                           defaultValue: "Linking gives c11 a shell on %@ as you."), consentHost))
                    .font(.system(size: 13, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("MachineSetupConsentHeadline")
                ForEach(consentBullets, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                }
                Button(String(localized: "machineSetup.consent.trustLink", defaultValue: "How c11 trusts a linked machine")) {
                    showingTrust = true
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .accessibilityIdentifier("MachineSetupTrustLink")
            }
            .frame(maxWidth: .infinity, minHeight: Self.bodyHeight, alignment: .topLeading)
            HStack {
                Spacer()
                Button(String(localized: "machineSetup.consent.back", defaultValue: "Back")) { consenting = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("MachineSetupConsentBack")
                Button(String(format: String(localized: "machineSetup.consent.link", defaultValue: "Link %@"), consentHost)) {
                    consenting = false
                    begin()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("MachineSetupConsentLink")
            }
        }
    }

    private var consentBullets: [String] {
        [
            String(localized: "machineSetup.consent.keys",
                   defaultValue: "c11 signs in with your SSH keys, installs its own hc there and starts it whenever this Mac connects, and never forwards your SSH agent, X11 or ports there."),
            String(localized: "machineSetup.consent.asYou",
                   defaultValue: "Anything you or an agent runs in a c11 terminal there runs as you, with your files and keys on that machine."),
            String(format: String(localized: "machineSetup.consent.sameAccount",
                                  defaultValue: "Any program running as you on %@ can read and type into the c11 terminals there. hc has no per-program check."),
                   consentHost),
            String(localized: "machineSetup.consent.checks",
                   defaultValue: "c11 checks hc's hash before it runs it, keeps hc's folders private, and records every cross-machine action in its audit log. For a Linux machine, c11 first downloads its Linux hc and c11 from c11's release, about 75 MB once, and checks each against this build's hash."),
        ]
    }

    private var formPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            formBody
                .frame(maxWidth: .infinity, minHeight: Self.bodyHeight, alignment: .topLeading)
            formButtons
        }
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "machineSetup.intro",
                        defaultValue: "c11 signs in to the other machine (a Mac, or a Linux machine) with your SSH keys, installs its own hc there, and links it. Terminals you open on it run there and appear here."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(String(localized: "machineSetup.host", defaultValue: "SSH host"))
                    TextField(String(localized: "machineSetup.hostPlaceholder", defaultValue: "studio, me@studio.local"), text: $host)
                        .textFieldStyle(.roundedBorder)
                        // C11H-332: Update is bound to the host the machine is linked through.
                        .disabled(request.update || model.running || model.result != nil)
                        .accessibilityIdentifier("MachineSetupHost")
                        .onSubmit(start)
                }
                GridRow {
                    Text(String(localized: "machineSetup.name", defaultValue: "Name"))
                    TextField(HCMachineSetup.defaultName(forHost: host).isEmpty ? "studio" : HCMachineSetup.defaultName(forHost: host),
                              text: $name)
                        .textFieldStyle(.roundedBorder)
                        .disabled(request.update || model.running || model.result != nil)
                        .accessibilityIdentifier("MachineSetupName")
                        .onSubmit(start)
                }
            }
            .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.rows) { row in
                    HStack(spacing: 8) {
                        stepIcon(row.state)
                            .frame(width: 16, height: 16)
                        Text(row.step.title)
                            .font(.system(size: 13, weight: row.state == .running ? .semibold : .regular))
                        if let detail = row.detail, row.state != .failed {
                            Text(detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(height: 20)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("MachineSetupStep.\(row.step.rawValue)")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))

            Group {
                if let failure = model.failure {
                    Text(failure)
                        .foregroundStyle(Color.red)
                        .accessibilityIdentifier("MachineSetupFailure")
                } else if let result = model.result {
                    Text(String(format: String(localized: "machineSetup.done",
                                               defaultValue: "%@ is linked. Open a terminal there with File > New Terminal on %@, or pick it when c11 asks."),
                                result.name, HCMachineTarget.displayName(result.name)))
                        .foregroundStyle(Color.green)
                        .accessibilityIdentifier("MachineSetupDone")
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 32, alignment: .topLeading)
        }
    }

    private var formButtons: some View {
        HStack {
            Spacer()
            Button(model.result == nil
                   ? String(localized: "machineSetup.cancel", defaultValue: "Cancel")
                   : String(localized: "machineSetup.close", defaultValue: "Done"), action: onClose)
                .keyboardShortcut(.cancelAction)
                .disabled(model.running)
                .accessibilityIdentifier("MachineSetupClose")
            if model.result == nil {
                Button(request.update
                       ? String(localized: "machineSetup.updateButton", defaultValue: "Update")
                       : String(localized: "machineSetup.addButton", defaultValue: "Add"), action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
                    .accessibilityIdentifier("MachineSetupStart")
            }
        }
    }

    /// Add on a new machine asks first; Update (already linked) starts.
    private func start() {
        guard canStart else { return }
        if request.update { begin() } else { consenting = true }
    }

    private func begin() {
        guard canStart else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.start(host: host.trimmingCharacters(in: .whitespaces),
                    name: trimmed.isEmpty ? nil : trimmed, update: request.update)
    }

    @ViewBuilder
    private func stepIcon(_ state: HCMachineSetupState?) -> some View {
        switch state {
        case nil:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        case .skipped:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.red)
        }
    }
}

struct RemoveMachineSheet: View {
    let request: RemoveMachineRequest
    /// A status line for the Machines card (nil keeps it), and whether it is an error.
    let onClose: (String?, Bool) -> Void

    @State private var terminals: [MachineRemoval.Terminal] = []
    @State private var removing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: String(localized: "machineRemove.title", defaultValue: "Remove %@?"), request.name))
                .font(.system(size: 17, weight: .semibold))
            if terminals.isEmpty {
                Text(String(localized: "machineRemove.none",
                            defaultValue: "No c11 terminals are open on it. c11 unlinks it; you can add it again later."))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(terminals.count == 1
                     ? String(localized: "machineRemove.endingOne",
                              defaultValue: "This c11 terminal on it will end, with everything it started:")
                     : String(format: String(localized: "machineRemove.ending",
                                             defaultValue: "These %lld c11 terminals on it will end, with everything they started:"),
                              terminals.count))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(terminals) { terminal in
                            Text("\(terminal.workspaceTitle) · \(terminal.title)")
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .accessibilityIdentifier("MachineRemoveTerminals")
            }
            HStack {
                Spacer()
                Button(String(localized: "machineRemove.cancel", defaultValue: "Cancel")) { onClose(nil, false) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(removing)
                Button(String(localized: "machineRemove.confirm", defaultValue: "Remove"), role: .destructive) {
                    removing = true
                    MachineRemoval.remove(machine: request.machine, session: request.session) { outcome in
                        switch outcome {
                        case .success(let value) where value.outcome.c11hLink && value.outcome.linkWasUp:
                            onClose(String(format: String(localized: "machineRemove.removedC11hLink",
                                                          defaultValue: "%@ removed; its c11h terminals ended. c11h's hc still runs there with no terminals: c11 stops only an hc it installed."),
                                           request.name), true)
                        case .success(let value) where value.outcome.c11hLink:
                            onClose(String(format: String(localized: "machineRemove.removedC11hLinkDown",
                                                          defaultValue: "%@ removed. Its link was down, so its c11h terminals and c11h's hc there may still run: c11 stops only an hc it installed."),
                                           request.name), true)
                        case .success(let value) where value.outcome.stopRefused:
                            onClose(String(format: String(localized: "machineRemove.removedUnverified",
                                                          defaultValue: "%@ removed. c11 couldn't confirm the hc there is its own, so it didn't stop it; it keeps running until it ends there."),
                                           request.name), true)
                        case .success(let value) where value.outcome.leftRunning:
                            onClose(String(format: String(localized: "machineRemove.removedUnreachable",
                                                          defaultValue: "%@ removed. Its link was down, so c11 couldn't end what it runs there; that keeps running until the machine's hc stops."),
                                           request.name), true)
                        case .success(let value):
                            let ended = value.ended
                            onClose(ended == 1
                                    ? String(format: String(localized: "machineRemove.removedOne",
                                                            defaultValue: "%@ removed; 1 terminal ended."), request.name)
                                    : String(format: String(localized: "machineRemove.removed",
                                                            defaultValue: "%@ removed; %lld terminals ended."), request.name, ended),
                                    false)
                        case .failure(let failure):
                            onClose(failure.message, true)
                        }
                    }
                }
                .disabled(removing)
                .accessibilityIdentifier("MachineRemoveConfirm")
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { terminals = MachineRemoval.terminals(on: request.machine, session: request.session) }
    }
}


/// C11H-332: the trust page (`c11 guide trust`), read from this build's own
/// bundled skill and shown over the consent page. Offline, read-only.
struct TrustPageSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "machineSetup.trust.title", defaultValue: "How c11 trusts a linked machine"))
                .font(.system(size: 17, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let body = Self.pageBody() {
                        // The sheet's own title stands for the page's first heading.
                        ForEach(Array(TrustPageBlock.parse(body).filter { $0.isTitle == false }.enumerated()), id: \.offset) { _, block in
                            block.view
                        }
                    } else {
                        Text(String(localized: "machineSetup.trust.missing",
                                    defaultValue: "This build has no trust page. Run “c11 guide trust” in a terminal."))
                            .font(.system(size: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(height: 420)
            .accessibilityIdentifier("MachineSetupTrustPage")
            HStack {
                Spacer()
                Button(String(localized: "machineSetup.trust.done", defaultValue: "Done"), action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("MachineSetupTrustDone")
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    static func pageBody(bundle: URL = Bundle.main.bundleURL) -> String? {
        try? BundledSkill(root: bundle.appendingPathComponent("Contents/Resources/skills/c11")).load(page: "trust").body
    }
}

/// The few markdown shapes the trust page uses: headings, bullets, paragraphs.
enum TrustPageBlock: Equatable {
    case title(String)
    case heading(String)
    case bullet(String)
    case paragraph(String)

    var isTitle: Bool { if case .title = self { return true } else { return false } }

    static func parse(_ markdown: String) -> [TrustPageBlock] {
        var blocks: [TrustPageBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("## ") { flush(); blocks.append(.heading(String(line.dropFirst(3)))); continue }
            if line.hasPrefix("# ") { flush(); blocks.append(.title(String(line.dropFirst(2)))); continue }
            if line.hasPrefix("- ") { flush(); blocks.append(.bullet(String(line.dropFirst(2)))); continue }
            if case .bullet(let text)? = blocks.last, paragraph.isEmpty, raw.hasPrefix("  ") {
                blocks[blocks.count - 1] = .bullet(text + " " + line)
                continue
            }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    private static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    @ViewBuilder var view: some View {
        switch self {
        case .title(let text):
            Self.inline(text).font(.system(size: 15, weight: .semibold))
        case .heading(let text):
            Self.inline(text).font(.system(size: 13, weight: .semibold)).padding(.top, 4)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•")
                Self.inline(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
        case .paragraph(let text):
            Self.inline(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
