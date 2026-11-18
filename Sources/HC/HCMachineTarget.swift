import Foundation

/// Where a terminal panel's hc session runs when it is not this Mac (ticket 12).
/// `machine` is the hc machine name (`hc machine ls`); `cwd` is a path on that
/// machine and is never resolved, validated or probed locally.
struct HCRemoteTarget: Equatable, Codable, Sendable {
    let machine: String
    let cwd: String?

    init(machine: String, cwd: String? = nil) {
        self.machine = machine
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cwd = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

/// How a new terminal panel picks its machine.
enum HCMachineRequest: Equatable, Sendable {
    /// This Mac. Every pre-existing creation path (restore of a local panel,
    /// layout plans, the default new tab) keeps this.
    case local
    /// The source panel's machine: a split of a studio panel stays on studio.
    case inherit
    /// An explicit, already validated machine (`--on studio`, the menu).
    case on(String)
    /// A target already decided, used as is: a saved panel's, or the one a
    /// split computed from the terminal it was split from.
    case restored(HCRemoteTarget)
    /// C11H-396: a layout plan's terminal on its recorded machine (workspace
    /// apply): placed as given, like `.restored`, but it is a new terminal,
    /// so it is refused up front when that machine's routed link is unusable.
    case planned(HCRemoteTarget)
}

/// The source of an inherited placement: the panel it was split from.
struct HCRemoteSource: Equatable, Sendable {
    let target: HCRemoteTarget
    /// Its live record, when the inventory has one: the folder it is in now.
    let record: HCTerminalRecord?

    /// The remote folder a new terminal beside this one starts in: what the
    /// foreground program reports, else the terminal's start folder, else the
    /// folder this panel itself was asked for (rows 29, 43).
    var currentDirectory: String? {
        if let cwd = record?.foreground?.cwd, !cwd.isEmpty { return cwd }
        if let cwd = record?.cwd, !cwd.isEmpty { return cwd }
        return target.cwd
    }
}

enum HCMachineTargetError: Error, Equatable {
    /// The hc backend is not active or its inventory is not ready yet.
    case unavailable
    /// No machine by that name; `known` lists the names hc has.
    case unknown(requested: String, known: [String])
    /// The machine is added but its line is down right now.
    case disconnected(String)
    /// Browsers and markdown stay local.
    case notTerminal
    /// C11H-274: its stored link doesn't check c11's hc and c11 couldn't
    /// update it (`HCStoredLinks`), so c11 opens nothing there. Refused before
    /// a panel exists, so no blank panel is left behind.
    case linkUnusable(String)

    var code: String {
        switch self {
        case .unavailable: return "hc_unavailable"
        case .unknown: return "machine_unknown"
        case .disconnected: return "machine_unreachable"
        case .notTerminal: return "remote_unsupported"
        case .linkUnusable: return "machine_link_unusable"
        }
    }

    var message: String {
        switch self {
        case .unavailable:
            return String(localized: "hc.machine.error.unavailable",
                defaultValue: "Terminals on other machines need the hc backend, which is not ready.")
        case .unknown(let requested, let known):
            let names = known.isEmpty
                ? String(localized: "hc.machine.error.none", defaultValue: "none added")
                : known.joined(separator: ", ")
            return String(format: String(localized: "hc.machine.error.unknown",
                defaultValue: "No machine named '%@'. Machines: %@."), requested, names)
        case .disconnected(let machine):
            return String(format: String(localized: "hc.machine.error.disconnected",
                defaultValue: "Machine '%@' is not connected right now."), machine)
        case .notTerminal:
            return String(localized: "hc.machine.error.notTerminal",
                defaultValue: "--on is only for terminal panels. Browsers and markdown stay on this Mac.")
        case .linkUnusable(let machine):
            return String(format: String(localized: "hc.machine.error.linkUnusable",
                defaultValue: "c11 won't use %@'s link: it doesn't check c11's hc and c11 couldn't update it. Update or Remove the machine in Settings > Herder Topography."),
                machine)
        }
    }
}

enum HCMachineTarget {
    /// `--on local` (or `here`) asks for this Mac explicitly, overriding inheritance.
    static let localWords: Set<String> = ["local", "here"]

    /// Validate an `--on` value against the live inventory. `.success(nil)`
    /// means this Mac. Matching is exact on hc's machine name, then
    /// case-insensitive when that is unambiguous ("Studio" finds "studio").
    /// `unusable`: machines whose stored link c11 won't use (C11H-274); one
    /// is refused even while hc reports its line connected.
    static func resolve(requested raw: String, snapshot: HCInventorySnapshot?,
                        unusable: Set<String> = []) -> Result<String?, HCMachineTargetError> {
        resolve(requested: raw, snapshot: snapshot,
                view: snapshot.map { HCMachineLinkView(machines: $0.machines, unusable: unusable) })
    }

    /// C11H-391: the same check against the link a new terminal would use.
    /// With `unusableBySession`, a pool snapshot is routed per name
    /// (`HCMachineRouting`): a name unusable in one session and usable in
    /// another resolves, and creation goes to the usable link.
    /// C11H-396: `starting`: names the links session lists while it starts,
    /// before its first report. Its link of such a name may be the usable
    /// one, so the name is not ready yet (`hc_unavailable`), never unknown
    /// or unusable from another session's older link.
    static func resolve(requested raw: String, snapshot: HCInventorySnapshot?,
                        unusableBySession: [String: Set<String>],
                        starting: Set<String> = []) -> Result<String?, HCMachineTargetError> {
        resolve(requested: raw, snapshot: snapshot,
                view: snapshot.map { HCMachineLinkView.of($0, unusableBySession: unusableBySession) },
                starting: starting)
    }

    /// The `--on` check against the app's live link state (`HCLinkedMachines`).
    static func resolve(requested raw: String, snapshot: HCInventorySnapshot?,
                        linked: HCLinkedMachines) -> Result<String?, HCMachineTargetError> {
        resolve(requested: raw, snapshot: snapshot, unusableBySession: linked.unusableSessions(),
                starting: linked.startingLinks())
    }

    private static func resolve(requested raw: String, snapshot: HCInventorySnapshot?,
                                view: HCMachineLinkView?,
                                starting: Set<String> = []) -> Result<String?, HCMachineTargetError> {
        let requested = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if localWords.contains(requested.lowercased()) { return .success(nil) }
        guard let snapshot, let view, case .ready = snapshot.readiness else { return .failure(.unavailable) }
        let names = view.machines.keys.sorted()
        let name: String
        if view.machines[requested] != nil {
            name = requested
        } else {
            let folded = names.filter { $0.caseInsensitiveCompare(requested) == .orderedSame }
            guard folded.count == 1 else {
                if starting.contains(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
                    return .failure(.unavailable)
                }
                return .failure(.unknown(requested: requested, known: names))
            }
            name = folded[0]
        }
        if view.unusable.contains(name) { return .failure(starting.contains(name) ? .unavailable : .linkUnusable(name)) }
        guard view.machines[name] == .connected else { return .failure(.disconnected(name)) }
        return .success(name)
    }

    /// The machines a new terminal can be opened on right now, for menus.
    static func connectedMachines(_ snapshot: HCInventorySnapshot?) -> [String] {
        guard let snapshot, case .ready = snapshot.readiness else { return [] }
        return snapshot.machines.filter { $0.value == .connected }.keys.sorted()
    }

    /// Decide a new terminal's placement. Nil runs on this Mac.
    /// - explicitCwd: a caller's `--cwd`, taken verbatim as a path on the target.
    /// - source: the panel the new one is created from, when it is remote.
    static func placement(request: HCMachineRequest, explicitCwd: String?, source: HCRemoteSource?) -> HCRemoteTarget? {
        switch request {
        case .local:
            return nil
        case .restored(let target), .planned(let target):
            return target
        case .on(let machine):
            let inherited = source?.target.machine == machine ? source?.currentDirectory : nil
            return HCRemoteTarget(machine: machine, cwd: explicitCwd ?? inherited)
        case .inherit:
            guard let source else { return nil }
            return HCRemoteTarget(machine: source.target.machine, cwd: explicitCwd ?? source.currentDirectory)
        }
    }

    /// The exact key and machine a remote panel's status binding observes, or
    /// nil while no key is known (a creation still pending) or after its end.
    static func statusBinding(_ lifecycle: HCLifecycle, target: HCRemoteTarget) -> (HCTerminalKey, String)? {
        switch lifecycle {
        case .live(let record):
            return (record.key, record.machineName ?? target.machine)
        case .unresolved(let identity, _):
            guard let key = identity.key else { return nil }
            return (key, target.machine)
        case .new, .ended:
            return nil
        }
    }

    /// The chip's name for a machine: hc's name with its first letter raised
    /// ("studio" reads "Studio"). Display only; identity and routing keep hc's name.
    static func displayName(_ machine: String) -> String {
        guard let first = machine.first else { return machine }
        return first.uppercased() + machine.dropFirst()
    }

    /// The part of a local terminal's environment that means the same thing on
    /// another machine: the panel's identity and agent identity, colour and
    /// locale. Paths into this Mac (PATH, ZDOTDIR, TERMINFO, the socket, the
    /// bundle, Ghostty resources, shell integration) are left out, so the
    /// remote login shell builds its own. hc sets TERM and the HC_* values.
    /// `relay` is the machine's c11 relay env (C11H-16: ZDOTDIR and the
    /// fail-closed socket paths), merged last so it wins over local values.
    static func remoteEnvironment(_ local: [String: String], relay: [String: String]? = nil) -> [String: String] {
        let portable = local.filter { key, _ in
            portableKeys.contains(key) || key.hasPrefix("C11_AGENT_") || key.hasPrefix("LC_")
        }
        return portable.merging(relay ?? [:]) { _, relayValue in relayValue }
    }

    /// The remote terminal's launch line. C11H-176: when c11 handed the
    /// terminal a relay credential pickup, the relay `c11` claims it once and
    /// exports the credential before the login shell starts, whatever that
    /// shell is. Any failure prints nothing, and the shell starts regardless;
    /// the pickup variable is unset either way.
    ///
    /// Pathfinder (2026-11-03): first, `C11_START_DIR` (a path relative to the
    /// remote home, set by `startDirectoryHint`) is tried as the start folder;
    /// when it is missing there the shell stays in that machine's home.
    ///
    /// C11H-392: bash has no `ZDOTDIR`, so when the machine's relay kit names a
    /// bash startup file (`C11_RELAY_BASHRC`, from its manifest) and the
    /// shell is bash (a Linux machine's), the shell starts as
    /// `bash --rcfile <it> -i`: the kit's file reads what a login bash reads,
    /// then puts the relay `c11` first on PATH. Any other shell, or no such
    /// file, starts as a login shell, as before.
    static let remoteLaunchLine = #"[ -n "${C11_START_DIR:-}" ] && cd "$HOME/$C11_START_DIR" 2>/dev/null; unset C11_START_DIR; [ -n "${C11_RELAY_PICKUP:-}" ] && [ -x "${C11_RELAY_BIN:-/nonexistent}/c11" ] && eval "$("$C11_RELAY_BIN/c11" relay-pickup 2>/dev/null)"; unset C11_RELAY_PICKUP; if [ -n "${C11_RELAY_BASHRC:-}" ] && [ -r "$C11_RELAY_BASHRC" ] && [ "${SHELL##*/}" = bash ]; then exec "$SHELL" --rcfile "$C11_RELAY_BASHRC" -i; fi; unset C11_RELAY_BASHRC; exec "${SHELL:-/bin/sh}" -l"#

    /// The variable that carries `startDirectoryHint` to the remote launch line.
    static let startDirectoryVariable = "C11_START_DIR"

    /// Pathfinder (2026-11-03): where a new terminal on another machine starts
    /// when nobody named a folder there. A local workspace root under this
    /// Mac's home maps to the same home-relative path on the other machine
    /// (`~/Projects/x` here is tried as `~/Projects/x` there; the launch line
    /// falls back to that machine's home when it is missing). A root outside
    /// the home, the home itself, or a path with `..` gives nil: start at home.
    static func startDirectoryHint(localRoot: String?, localHome: String) -> String? {
        guard let localRoot else { return nil }
        let root = (localRoot as NSString).standardizingPath
        var home = (localHome as NSString).standardizingPath
        guard !home.isEmpty, home != "/" else { return nil }
        if !home.hasSuffix("/") { home += "/" }
        guard root.hasPrefix(home) else { return nil }
        let relative = String(root.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty,
              !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return relative
    }

    static let portableKeys: Set<String> = [
        "C11_START_DIR",
        "C11_PANEL_ID", "C11_WORKSPACE_ID", "C11_SURFACE_ID", "C11_PANEL_NUM",
        "CMUX_PANEL_ID", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID",
        "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "LANG",
    ]
}

extension HCPanelLaunchSpec {
    /// The one place a panel's launch becomes a local or a remote spec. A
    /// remote spec runs a login shell on the machine, starts in the
    /// target's folder (or that machine's home), carries only the portable
    /// environment, and keeps the initial input (launch-agent types its
    /// command into that shell).
    static func placed(argv: [String], localCwd: String?, environment: [String: String],
                       initialInput: HCInitialInput?, workspaceID: UUID? = nil,
                       remote: HCRemoteTarget?, panelEnvironment: [String: String] = [:],
                       session: String? = nil) -> HCPanelLaunchSpec {
        guard let remote else {
            return HCPanelLaunchSpec(argv: argv, cwd: localCwd, environment: environment, initialInput: initialInput,
                                     workspaceID: workspaceID)
        }
        // C11H-78: the relay environment of the shard the terminal is created
        // in; each shard's link to the machine has its own manifest.
        let relay = C11RelayEnvironment.forMachine(remote.machine, session: session)
        // C11H-86: a terminal on another machine with no relay has that machine's own
        // c11 and claude on PATH; say so where the operator and the kit look.
        if relay.isEmpty { C11RelayLog.event("no_manifest machine=\(remote.machine)\(session.map { " session=\($0)" } ?? "")") }
        var remoteEnvironment = HCMachineTarget.remoteEnvironment(environment, relay: relay)
        // The merged local environment includes the app's inherited XDG path.
        // Only an explicit panel value means anything on the other machine.
        remoteEnvironment["XDG_CONFIG_HOME"] = panelEnvironment["XDG_CONFIG_HOME"]
        // Resolve SHELL on the far machine. Neither this Mac's shell nor a
        // particular remote shell binary is portable to every linked host.
        let remoteArgv = ["/bin/sh", "-c", HCMachineTarget.remoteLaunchLine]
        return HCPanelLaunchSpec(argv: remoteArgv, cwd: remote.cwd,
                                 environment: remoteEnvironment,
                                 initialInput: initialInput, workspaceID: workspaceID, machine: remote.machine)
    }
}

/// Sends a file beside a terminal on its machine (hc `terminal.put`).
protocol HCFileTransfer: Sendable {
    func put(_ key: HCTerminalKey, name: String, data: Data) async throws -> String
}

extension HCManagedSession: HCFileTransfer {}

/// Ticket 12 (row 23): a file dropped on a terminal that runs on another
/// machine. Its local path means nothing there, so each file is sent first
/// and the paths it landed at are what gets pasted. Every file is checked
/// before any byte is sent, and nothing is pasted unless every file arrived.
/// The sends themselves are one put per file: if a later one fails, earlier
/// files are already on that machine (a retry sends them again).
enum HCRemoteFileDrop {
    /// hc's inline limit for one put (`put.rs` MAX_BYTES).
    static let maximumBytes = 8 << 20
    /// Generous for 8 MiB over a relayed link; one RPC, never retried.
    static let seconds: TimeInterval = 30

    enum Failure: Error, Equatable {
        case notAFile(String)
        case tooLarge(String)
        case unreadable(String)
        case transfer(String, HCUnavailableReason)
    }

    struct Item: Equatable {
        let name: String
        let data: Data
    }

    /// Reads the files (call off-main). Directories, unreadable files and any
    /// file over the limit fail the whole drop before anything is sent.
    static func read(_ urls: [URL], fileManager: FileManager = .default) -> Result<[Item], Failure> {
        var items: [Item] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard url.isFileURL, fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return .failure(.notAFile(url.lastPathComponent)) }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
            guard size >= 0 else { return .failure(.unreadable(url.lastPathComponent)) }
            guard size <= maximumBytes else { return .failure(.tooLarge(url.lastPathComponent)) }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return .failure(.unreadable(url.lastPathComponent))
            }
            guard data.count <= maximumBytes else { return .failure(.tooLarge(url.lastPathComponent)) }
            items.append(Item(name: url.lastPathComponent, data: data))
        }
        return .success(items)
    }

    /// Sends each item in order and returns the text to paste: the remote
    /// paths, shell-escaped, joined by spaces (what a local drop pastes).
    static func send(_ items: [Item], to key: HCTerminalKey, via transfer: any HCFileTransfer,
                     escape: (String) -> String) async -> Result<String, Failure> {
        var paths: [String] = []
        for item in items {
            do { paths.append(try await transfer.put(key, name: item.name, data: item.data)) }
            catch { return .failure(.transfer(item.name, reason(error))) }
        }
        return .success(paths.map(escape).joined(separator: " "))
    }

    static func reason(_ error: Error) -> HCUnavailableReason {
        (error as? HCUnavailableReason) ?? (error as? HCRPCFailure)?.reason ?? .malformedResponse
    }
}

/// C11H-363: what a drop onto a terminal does. Sending files to another
/// machine is the operator's call, made on files they picked outside c11. A
/// drag that started inside c11 (the titlebar folder icon, a web view, the
/// sidebar) can carry a path another machine chose, so it never sends one.
enum TerminalFileDropPolicy {
    enum Decision: Equatable {
        /// The existing paste: a terminal on this Mac, or no file in the drop.
        case paste
        /// A file dragged from inside c11 onto a terminal on another machine.
        case refuse
        /// Files from outside c11 onto a terminal on another machine: ask first.
        case ask([URL])
    }

    static func decide(urls: [URL], targetIsRemote: Bool, startedInsideC11: Bool) -> Decision {
        guard targetIsRemote, urls.contains(where: \.isFileURL) else { return .paste }
        if startedInsideC11 { return .refuse }
        return urls.allSatisfy(\.isFileURL) ? .ask(urls) : .paste
    }

    /// The drag cursor's answer while a drag moves over a terminal, from the
    /// pasteboard's types alone (nothing is read): true shows no operation.
    static func refusesDrag(hasFileURL: Bool, targetIsRemote: Bool, startedInsideC11: Bool) -> Bool {
        hasFileURL && targetIsRemote && startedInsideC11
    }
}

/// C11H-363: one file drop onto a terminal on another machine, from the
/// operator's answer to its audit record. Nothing is read or sent until the
/// operator answers Send, and every drop (sent, cancelled, refused or failed)
/// writes exactly one `file_transfer` record. The effects are injected so the
/// order is tested without a window or a link.
@MainActor
struct HCRemoteFileDropFlow {
    struct Target: Equatable, Sendable {
        /// The terminal the drop was aimed at; nil while hc has no key or no
        /// transfer for it, which fails the drop before anything is asked.
        let key: HCTerminalKey?
        let machine: String?
        let panelID: UUID
        let workspaceID: UUID?
    }

    enum Outcome: Equatable {
        case sent
        case cancelled
        case refused(String)
        case failed(String)

        var word: String {
            switch self {
            case .sent: return "ok"
            case .cancelled: return "cancelled"
            case .refused: return "refused"
            case .failed: return "failed"
            }
        }

        var code: String? {
            switch self {
            case .sent: return nil
            case .cancelled: return "declined"
            case .refused(let code), .failed(let code): return code
            }
        }
    }

    /// Shows the question and calls `answer` once, later, with true for Send.
    /// Returns false when it cannot be shown (no window): the drop is refused.
    var ask: (_ urls: [URL], _ machine: String, _ answer: @escaping @MainActor (Bool) -> Void) -> Bool
    /// Reads the files and sends them (off main); the text to paste on success.
    var send: @Sendable (_ urls: [URL], _ key: HCTerminalKey) async -> Result<String, HCRemoteFileDrop.Failure>
    /// Whether the panel still holds the terminal the drop was aimed at.
    var stillBound: (_ key: HCTerminalKey) -> Bool
    var paste: (_ text: String) -> Void
    /// Every outcome but `sent`: the beep, and a notice where one helps.
    var unsent: (_ outcome: Outcome) -> Void
    var audit: (_ record: C11AuditRecord) -> Void

    /// A file dragged from inside c11: refused before any file is read.
    func refuseInApp(_ urls: [URL], target: Target) {
        finish(.refused("in_app_source"), urls: urls, target: target)
    }

    func start(_ urls: [URL], target: Target) {
        guard let key = target.key, let machine = target.machine else {
            finish(.failed("hc_unavailable"), urls: urls, target: target)
            return
        }
        let shown = ask(urls, machine) { approved in
            guard approved else { finish(.cancelled, urls: urls, target: target); return }
            guard stillBound(key) else { finish(.failed("target_changed"), urls: urls, target: target); return }
            Task { @MainActor in
                switch await self.send(urls, key) {
                case .success(let text) where stillBound(key):
                    paste(text)
                    finish(.sent, urls: urls, target: target)
                case .success:
                    finish(.failed("target_changed"), urls: urls, target: target)
                case .failure(let failure):
                    finish(.failed(Self.code(failure)), urls: urls, target: target)
                }
            }
        }
        if !shown { finish(.refused("no_window"), urls: urls, target: target) }
    }

    private func finish(_ outcome: Outcome, urls: [URL], target: Target) {
        audit(Self.record(outcome, urls: urls, target: target))
        if outcome != .sent { unsent(outcome) }
    }

    static func code(_ failure: HCRemoteFileDrop.Failure) -> String {
        switch failure {
        case .notAFile: return "not_a_file"
        case .tooLarge: return "too_large"
        case .unreadable: return "unreadable"
        case .transfer(_, let reason): return "hc_" + reason.rawValue
        }
    }

    /// Who, where and what: the local files by name (the first by path), the
    /// machine and panel. Never a file's contents or the pasted text.
    static func record(_ outcome: Outcome, urls: [URL], target: Target) -> C11AuditRecord {
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        return C11AuditRecord(kind: .fileTransfer, via: "drop", outcome: outcome.word, machine: target.machine,
                              panel: target.panelID.uuidString, workspace: target.workspaceID?.uuidString,
                              path: urls.first?.path, code: outcome.code,
                              detail: "files=\(urls.count): \(names)")
    }
}

/// C11H-363: the question before files go to another machine. A window sheet
/// (`beginSheetModal`), never `runModal()`: it spins no nested run loop.
enum HCRemoteFileDropPrompt {
    static let listedNames = 8

    static func title(urls: [URL], machine: String) -> String {
        if urls.count == 1, let name = urls.first?.lastPathComponent {
            return String(format: String(localized: "terminal.remoteDrop.title.one",
                defaultValue: "Send \u{201C}%1$@\u{201D} to %2$@?"), name, machine)
        }
        return String(format: String(localized: "terminal.remoteDrop.title.many",
            defaultValue: "Send %1$lld files to %2$@?"), Int64(urls.count), machine)
    }

    static func body(urls: [URL], machine: String) -> String {
        let explanation = String(format: String(localized: "terminal.remoteDrop.body",
            defaultValue: "%@ gets a copy of each file, and the path it lands at is pasted into this terminal."), machine)
        guard urls.count > 1 else { return explanation }
        var lines = urls.prefix(listedNames).map(\.lastPathComponent)
        if urls.count > listedNames {
            lines.append(String(format: String(localized: "terminal.remoteDrop.more",
                defaultValue: "and %lld more"), Int64(urls.count - listedNames)))
        }
        return explanation + "\n\n" + lines.joined(separator: "\n")
    }

    static var sendButton: String { String(localized: "terminal.remoteDrop.send", defaultValue: "Send") }
    static var cancelButton: String { String(localized: "terminal.remoteDrop.cancel", defaultValue: "Cancel") }
    static var refusedInApp: String {
        String(localized: "terminal.remoteDrop.refusedInApp",
               defaultValue: "Files dragged from inside c11 aren't sent to another machine. Drag them from Finder to send them.")
    }
}

/// Ticket 12 (T12.1): an agent launched on another machine is told to read
/// its prompt file, so that file must exist there. The staged prompt is sent
/// beside the terminal with `terminal.put`; the launch is composed with the
/// path it landed at. Call off-main; nothing is retried.
enum HCRemoteLaunchPrompt {
    static func send(prompt url: URL, to key: HCTerminalKey,
                     via transfer: any HCFileTransfer) async -> Result<String, HCRemoteFileDrop.Failure> {
        switch HCRemoteFileDrop.read([url]) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let items):
            guard let item = items.first else { return .failure(.unreadable(url.lastPathComponent)) }
            do { return .success(try await transfer.put(key, name: item.name, data: item.data)) }
            catch { return .failure(.transfer(item.name, HCRemoteFileDrop.reason(error))) }
        }
    }
}
