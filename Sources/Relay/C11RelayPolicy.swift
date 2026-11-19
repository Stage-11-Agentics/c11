import Foundation

/// C11H-359 (L3): one machine link as c11 verified it. A machine name alone is
/// not a link: two shards can each link a machine under the same name, to
/// different accounts, and a link re-made under the same name has a new secret.
struct C11RelayLinkRef: Hashable, Sendable {
    /// The local hc session (shard) the link belongs to.
    let session: String
    let machine: String
    /// The id of the link secret the caller's credential was made from.
    let linkID: String
}

/// What c11 serves to a relayed request (plan ticket 14). Default deny: the
/// relay carries the talk-back verbs an agent uses about itself (identity,
/// title and description, metadata, sidebar status, flags, journal, mail) and
/// the reads they need. Typing into a terminal, creating or closing panels,
/// launching agents, browsers and markdown are refused, so the relay never
/// becomes a remote shell into c11's machine.
enum C11RelayPolicy {
    struct VerifiedCaller: Equatable, Sendable {
        let panel: UUID
        /// C11H-176 part B: the workspace that holds the panel now, from
        /// c11's own model (the service fills it); the request's claim is
        /// only a starting value and never names a write's target.
        var workspace: UUID?
        let machine: String
        let terminal: String
        /// The terminal's `c11.creation` label: the run its credential belongs to.
        var creation: UUID? = nil
        /// C11H-359 (L3): the link that verified this caller: its local hc
        /// session, its machine and the id of the secret its credential used.
        /// Set once the credential is authenticated.
        var link: C11RelayLinkRef? = nil

        /// C11H-371: what a relayed read may see, the caller's panel and the
        /// workspace that holds it now; nil while that workspace is unknown,
        /// and then a scoped read answers `not_found`.
        var readScope: ReadScope? {
            workspace.map { ReadScope(panel: panel, workspace: $0) }
        }
    }

    /// C11H-371: the reach of a relayed read. A linked machine's terminal
    /// reads the workspace that holds its own panel and nothing outside it.
    struct ReadScope: Equatable, Sendable {
        let panel: UUID
        let workspace: UUID
    }

    struct Refusal: Error, Equatable {
        let code: String
        let message: String
    }

    static let v2Methods: Set<String> = [
        // Reads.
        "system.ping", "system.capabilities", "system.identify", "system.tree", "system.brand",
        "window.list", "window.current", "workspace.list", "workspace.current", "workspace.get_metadata",
        "display.list",
        "panel.list", "panel.current", "panel.locate", "panel.family", "panel.get_metadata",
        "panel.get_titlebar_state", "area.list", "area.panels", "sidebar.state", "mailbox.resolve",
        // The flag-kind registry is a read, so an agent on another machine can
        // pick a registered kind; set and rm stay on c11's own machine (C11H-223).
        "flag.kind.list",
        // Talk-back writes.
        "panel.set_metadata", "workspace.set_metadata", "workspace.clear_metadata", "panel.action",
        "panel.trigger_flash", "flag.raise", "flag.lower", "agent.event.append", "notification.create_for_panel",
        // C11H-328: a Claude hook's report about its own panel for `c11 fleet`
        // (login name, final message, why a turn failed), bounded by
        // `AgentReportParser`; panel-scoped below.
        "agent.report",
    ]

    static let v1Commands: Set<String> = [
        "ping", "set_status", "clear_status", "list_status", "set_progress", "clear_progress",
        "log", "clear_log", "list_log",
    ]

    /// C11H-228: `c11 show` is the relay's one panel-creating verb. It opens a
    /// display-only viewer beside the verified caller and nowhere else; the
    /// machine its path is read on is the caller's own, never a parameter.
    static let showMethods: Set<String> = ["show.open", "show.close"]
    /// Parameters a relayed show may never carry: anything that would place
    /// the viewer elsewhere or read another machine.
    static let showForbiddenKeys: Set<String> = ["machine", "on", "container", "host", "session", "pane_id", "pane_ref"]

    /// `panel.action` carries only a rename through the relay.
    static let panelActions: Set<String> = ["rename"]

    private static let callerKeys = ["caller_panel_id", "caller_tab_id", "caller_surface_id"]
    /// The one refusal that is about timing, not the request: the service
    /// waits for a ready inventory before giving it (C11H-89).
    static let inventoryPendingCode = "relay_inventory_pending"

    /// The request's claimed identity, checked against the live inventory: the
    /// panel must be bound to a running terminal on the machine the request
    /// came from, and that terminal's id must equal the request's
    /// `HC_TERMINAL_ID`. Both are public on that machine (`hc ls`), so this
    /// only finds the terminal; `authenticate` proves the caller holds its
    /// credential (C11H-176).
    static func verify(_ request: C11Relay.Request, machine: String,
                       snapshot: HCInventorySnapshot) -> Result<VerifiedCaller, Refusal> {
        guard case .ready = snapshot.readiness else {
            return .failure(Refusal(code: inventoryPendingCode, message: C11RelayAuth.refusalText(inventoryPendingCode) ?? ""))
        }
        guard let panel = UUID(uuidString: request.panel) else { return .failure(identityRefusal) }
        let wanted = panel.uuidString.lowercased()
        // hc names the terminal `tN` on its own machine; accept `machine/tN` too.
        // The id must be hc's own local form (`HCLocalTerminalAddress`, e.g. `t1b`).
        let term = request.term.hasPrefix(machine + "/") ? String(request.term.dropFirst(machine.count + 1)) : request.term
        guard HCLocalTerminalAddress.isValid(term) else { return .failure(identityRefusal) }
        let match = snapshot.records.values.first { record in
            record.labels["c11.panel"]?.lowercased() == wanted
                && record.machineName == machine
                && record.key.localAddress == term
                && record.state == .running
        }
        guard let match else { return .failure(identityRefusal) }
        return .success(VerifiedCaller(panel: panel, workspace: request.workspace.flatMap(UUID.init(uuidString:)),
                                       machine: machine, terminal: request.term,
                                       creation: match.labels["c11.creation"].flatMap(UUID.init(uuidString:))))
    }

    /// C11H-176: the request must be signed with the credential c11 derived
    /// for this terminal's current run under the session's current link
    /// secret. Returns that credential, which also signs the reply.
    static func authenticate(_ request: C11Relay.Request, caller: VerifiedCaller, session: String,
                             link: C11RelayAuth.LinkSecret?) -> Result<Data, Refusal> {
        guard request.isSigned else { return .failure(authMissingRefusal) }
        guard let creation = caller.creation, UUID(uuidString: request.creation) == creation,
              let link, link.id == request.linkID else { return .failure(authRefusedRefusal) }
        let key = C11RelayAuth.terminalKey(link: link, session: session, machine: caller.machine,
                                            panel: caller.panel, creation: creation)
        guard C11RelayAuth.isSigned(request, key: key) else { return .failure(authRefusedRefusal) }
        return .success(key)
    }

    static var authMissingRefusal: Refusal {
        Refusal(code: C11RelayAuth.authMissingCode, message: C11RelayAuth.refusalText(C11RelayAuth.authMissingCode) ?? "")
    }

    static var authRefusedRefusal: Refusal {
        Refusal(code: C11RelayAuth.authRefusedCode, message: C11RelayAuth.refusalText(C11RelayAuth.authRefusedCode) ?? "")
    }

    static var staleRefusal: Refusal {
        Refusal(code: C11RelayAuth.staleCode,
                message: String(localized: "relay.error.stale",
                    defaultValue: "The request's nonce is too old (c11 restarted, or the link was down). Nothing ran. Retry."))
    }

    static var replayRefusal: Refusal {
        Refusal(code: C11RelayAuth.replayCode,
                message: String(localized: "relay.error.replay",
                    defaultValue: "This request already reached c11 once; this copy did not run."))
    }

    static var kitOutdatedRefusal: Refusal {
        Refusal(code: C11RelayAuth.kitOutdatedCode, message: C11RelayAuth.refusalText(C11RelayAuth.kitOutdatedCode) ?? "")
    }

    static var identityRefusal: Refusal {
        Refusal(code: "relay_identity_refused", message: C11RelayAuth.refusalText("relay_identity_refused") ?? "")
    }

    static var journalPanelRefusal: Refusal {
        Refusal(code: "relay_identity_refused",
                message: String(localized: "relay.error.journalPanel",
                    defaultValue: "Through the machine relay a journal event names only the calling panel."))
    }

    static func notAllowed(_ name: String) -> Refusal {
        if name.hasPrefix("browser.") || name.hasPrefix("markdown.") {
            return Refusal(code: "relay_not_allowed",
                           message: String(format: String(localized: "relay.error.notAllowedShow",
                               defaultValue: "%@ is not available through the machine relay. Test with a browser on your own machine, then `c11 show` the result."),
                               name))
        }
        return Refusal(code: "relay_not_allowed",
                message: String(format: String(localized: "relay.error.notAllowed",
                    defaultValue: "%@ is not available through the machine relay. It carries identity, titles, metadata, status, flags and mail."),
                    name))
    }

    enum Admitted: Equatable {
        /// A v2 line, rewritten so its caller fields name the verified panel.
        case v2(method: String, id: Any?, params: [String: Any], line: String)
        /// A v1 text command, passed through as is.
        case v1(command: String, line: String)

        static func == (lhs: Admitted, rhs: Admitted) -> Bool {
            switch (lhs, rhs) {
            case (.v2(let a, _, _, let x), .v2(let b, _, _, let y)): return a == b && x == y
            case (.v1(let a, let x), .v1(let b, let y)): return a == b && x == y
            default: return false
            }
        }
    }

    // MARK: Targets (C11H-176 part B)

    /// Writes that act on a panel, and on a workspace. Through the relay
    /// they may name only the caller's own panel and the workspace that
    /// holds it; a missing target is filled in with those.
    static let panelScopedWrites: Set<String> = [
        "panel.set_metadata", "panel.action", "panel.trigger_flash", "flag.raise", "flag.lower", "notification.create_for_panel",
        "agent.report",
    ]
    static let workspaceScopedWrites: Set<String> = ["workspace.set_metadata", "workspace.clear_metadata"]
    static let v1Writes: Set<String> = ["set_status", "clear_status", "set_progress", "clear_progress", "log", "clear_log"]
    /// Every spelling the socket accepts for a panel and a workspace target.
    static let panelTargetKeys: Set<String> = ["surface_id", "panel_id", "panel_ref", "tab_id", "tab_ref", "surface_ref"]
    static let workspaceTargetKeys: Set<String> = ["workspace_id", "workspace_ref"]
    /// v1 options that pick a target (or a process on the Mac): a relayed
    /// line never keeps its own; c11 writes the caller's.
    static let v1TargetOptions: Set<String> = ["tab", "workspace", "panel", "surface", "pane", "area", "window", "pid"]
    /// A notification's process id and Codex payload name things on the
    /// calling machine; c11 would look them up among its own.
    static let notificationLocalKeys: Set<String> = ["agent_pid", "legacy_codex_notify_payload_b64"]
    /// Mailbox identity a relayed panel may give itself only when no other
    /// live panel answers to that value (address, role or title).
    static let mailboxIdentityKeys: Set<String> = ["mailbox.address", "mailbox.role"]

    /// Any other key that names a window, workspace, area or panel (a
    /// target, source, before or after one): never allowed in a relayed write.
    static func isOtherTargetKey(_ key: String) -> Bool {
        key.range(of: #"^((target|source|before|after)_)?(window|workspace|pane|area|surface|panel|tab)(_(id|ref))?$"#,
                  options: .regularExpression) != nil
    }

    static func targetRefusal(_ name: String) -> Refusal {
        Refusal(code: "relay_target_refused",
                message: String(format: String(localized: "relay.error.target",
                    defaultValue: "%@: through the machine relay a write names only your own panel ($C11_PANEL_ID, as a UUID) and the workspace that holds it."),
                    name))
    }

    // MARK: c11's own identities and keys (C11H-360)

    /// Mail names c11 itself speaks as: the operator's point-and-say note and
    /// c11's own notices (`c11h` is the old identity, still an alias). No
    /// relayed panel may take one as its address or role, or send as one.
    static let reservedIdentities: Set<String> = ["operator", "c11", "c11h"]

    /// `value` as a reader would take it: compatibility-mapped (NFKC), every
    /// invisible format character removed, trimmed and lowercased.
    static func foldedIdentity(_ value: String) -> String {
        let mapped = value.precomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        for scalar in mapped.unicodeScalars where scalar.properties.generalCategory != .format {
            scalars.append(scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether `value`, or any item of a comma-separated list, folds to one of
    /// c11's own identities.
    static func isReservedIdentity(_ value: String) -> Bool {
        value.split(separator: ",", omittingEmptySubsequences: false)
            .contains { reservedIdentities.contains(foldedIdentity(String($0))) }
    }

    static let identityReservedCode = "relay_identity_reserved"

    static func identityReservedRefusal(_ value: String) -> Refusal {
        Refusal(code: identityReservedCode,
                message: String(format: String(localized: "relay.error.identityReserved",
                    defaultValue: "'%@' is a name c11 itself speaks as; through the machine relay a panel cannot take it or send as it."),
                    value))
    }

    /// Workspace keys c11 acts on itself: the Captain mail route and the
    /// Recovered workspace mark. A relayed write never sets or clears them,
    /// and never replaces or clears the whole object (which would too).
    static let reservedWorkspaceKeys: Set<String> = [WorkspaceMetadataKey.captain, "c11h.recovered"]
    /// Sidebar status keys and log sources c11 writes about the link itself.
    static let reservedSidebarPrefix = "remote."
    static let reservedLogSource = "remote"
    static let keyReservedCode = "relay_key_reserved"

    static func keyReservedRefusal(_ name: String) -> Refusal {
        Refusal(code: keyReservedCode,
                message: String(format: String(localized: "relay.error.keyReserved",
                    defaultValue: "%@: through the machine relay a write cannot set, clear or replace c11's own keys (captain, c11h.recovered, remote.* status, remote log sources)."),
                    name))
    }

    /// The refusal for a relayed workspace metadata write that would touch a
    /// reserved key, replace the object, or clear it whole; nil when it
    /// touches only ordinary keys. The handler applies the same rule.
    static func workspaceWriteRefusal(_ params: [String: Any], method: String) -> Refusal? {
        let clearing = method.hasSuffix(".clear_metadata")
        var keys: [String] = []
        var namesKeys = false
        if let raw = params["keys"], !(raw is NSNull) {
            namesKeys = true
            keys += (raw as? [String]) ?? []
            if !(raw is [String]) { return keyReservedRefusal(method) }
        }
        if let key = params["key"] {
            namesKeys = true
            guard let key = key as? String else { return keyReservedRefusal(method) }
            keys.append(key)
        }
        if clearing {
            guard namesKeys, !keys.isEmpty else { return keyReservedRefusal(method) }
        } else {
            if let mode = params["mode"] as? String, mode.lowercased() == "replace" { return keyReservedRefusal(method) }
            if let metadata = params["metadata"] as? [String: Any] { keys += metadata.keys }
        }
        return keys.contains(where: isReservedWorkspaceKey) ? keyReservedRefusal(method) : nil
    }

    static func isReservedWorkspaceKey(_ key: String) -> Bool {
        reservedWorkspaceKeys.contains(foldedIdentity(key))
    }

    static func identityTakenRefusal(_ value: String) -> Refusal {
        Refusal(code: "relay_identity_taken",
                message: String(format: String(localized: "relay.error.identityTaken",
                    defaultValue: "'%@' is already another panel's mail address, role or title; through the machine relay a panel cannot take it."),
                    value))
    }

    /// A v2 write's params with every target checked. Each panel target
    /// must be the caller's UUID; any other kind of target is refused. The
    /// workspace is always the one that holds the caller's panel in c11's
    /// model, whatever the request named (a moved panel's launch-time
    /// workspace is replaced, never followed). A missing panel target is
    /// filled in.
    static func scopedParams(_ params: [String: Any], method: String, caller: VerifiedCaller,
                             claimedWorkspace: String? = nil) -> Result<[String: Any], Refusal> {
        if scopedReads.contains(method) {
            return .success(scopedReadParams(params, method: method, caller: caller, claimedWorkspace: claimedWorkspace))
        }
        var params = params
        let panelScoped = panelScopedWrites.contains(method)
        guard panelScoped || workspaceScopedWrites.contains(method) else { return .success(params) }
        for (key, value) in params {
            if panelTargetKeys.contains(key) {
                guard let raw = value as? String, UUID(uuidString: raw) == caller.panel else { return .failure(targetRefusal(method)) }
            } else if workspaceTargetKeys.contains(key) {
                continue
            } else if isOtherTargetKey(key) {
                return .failure(targetRefusal(method))
            }
        }
        guard let workspace = caller.workspace else { return .failure(targetRefusal(method)) }
        for key in workspaceTargetKeys { params.removeValue(forKey: key) }
        params["workspace_id"] = workspace.uuidString
        if panelScoped, !params.keys.contains(where: panelTargetKeys.contains) {
            params["surface_id"] = caller.panel.uuidString
        }
        return .success(params)
    }

    // MARK: Reads (C11H-371)

    /// Reads that carry no panel or workspace of this Mac: served as asked.
    static let unscopedReads: Set<String> = [
        "system.ping", "system.capabilities", "system.brand", "flag.kind.list",
    ]
    /// Reads whose every target must lie in the caller's workspace. The relay
    /// executor checks them against c11's model before they run
    /// (`TerminalController.relayReadRefusal`); their handlers keep the reply
    /// inside that workspace (`SocketCommandContext.relayReadScope`).
    static let gatedReads: Set<String> = [
        "system.identify", "system.tree", "window.list", "window.current", "display.list",
        "workspace.list", "workspace.current", "workspace.get_metadata",
        "panel.list", "panel.current", "panel.locate", "panel.family", "panel.get_metadata",
        "panel.get_titlebar_state", "area.list", "area.panels", "sidebar.state",
    ]
    /// Mail routing reaches every workspace; its reply drops other panels'
    /// session ids instead.
    static let mailRoutingReads: Set<String> = ["mailbox.resolve"]
    static var scopedReads: Set<String> { gatedReads.union(mailRoutingReads) }
    /// Reads that fall back to the operator's selected workspace when none
    /// is named; through the relay they read the caller's.
    static let workspaceDefaultReads: Set<String> = [
        "system.tree", "workspace.list", "workspace.current", "workspace.get_metadata",
        "panel.list", "panel.current", "area.list", "area.panels", "sidebar.state",
    ]
    /// Reads that fall back to the focused panel when none is named; through
    /// the relay they read the caller's.
    static let panelDefaultReads: Set<String> = [
        "panel.locate", "panel.family", "panel.get_metadata", "panel.get_titlebar_state",
    ]
    /// v1 reads that name a workspace: rebuilt to name the caller's.
    static let v1Reads: Set<String> = ["list_status", "list_log"]

    static var readScopeRefusal: Refusal {
        Refusal(code: "not_found",
                message: String(localized: "relay.error.readScope",
                    defaultValue: "Not found. Through the machine relay a read sees only the workspace that holds your own panel."))
    }

    /// Whether a read param names a window, workspace, area or panel.
    static func isReadTargetKey(_ key: String) -> Bool {
        panelTargetKeys.contains(key) || workspaceTargetKeys.contains(key) || isOtherTargetKey(key)
    }

    enum ReadTargetKind: Equatable { case window, workspace, area, panel }

    /// The kind of thing a read target key names, from its noun (`window`,
    /// `workspace`, `pane` or `area`, else a panel: `panel`, `surface`, `tab`).
    static func readTargetKind(_ key: String) -> ReadTargetKind {
        var noun = Substring(key)
        for prefix in ["target_", "source_", "before_", "after_"] where noun.hasPrefix(prefix) {
            noun = noun.dropFirst(prefix.count)
        }
        for suffix in ["_id", "_ref"] where noun.hasSuffix(suffix) {
            noun = noun.dropLast(suffix.count)
        }
        switch noun {
        case "window": return .window
        case "workspace": return .workspace
        case "pane", "area": return .area
        default: return .panel
        }
    }

    /// A relayed read's params with no fallback left to the operator's
    /// selection: a missing workspace or panel is the caller's, every window
    /// scope is the caller's workspace, and identify's caller is the verified
    /// one. The workspace the request claimed (its launch-time
    /// `C11_WORKSPACE_ID`) names the caller's own, as for writes, so a moved
    /// panel keeps reading its workspace. Other named targets are left for
    /// the executor's gate. With no read scope the params pass as they are
    /// and the executor refuses the read.
    static func scopedReadParams(_ params: [String: Any], method: String, caller: VerifiedCaller,
                                 claimedWorkspace: String? = nil) -> [String: Any] {
        guard let scope = caller.readScope else { return params }
        var params = params
        if let claimed = claimedWorkspace.flatMap(UUID.init(uuidString:)), claimed != scope.workspace {
            for key in workspaceTargetKeys where (params[key] as? String).flatMap(UUID.init(uuidString:)) == claimed {
                params[key] = scope.workspace.uuidString
            }
        }
        if workspaceDefaultReads.contains(method), params["workspace_id"] == nil {
            params["workspace_id"] = scope.workspace.uuidString
        }
        if panelDefaultReads.contains(method), !params.keys.contains(where: panelTargetKeys.contains) {
            params["surface_id"] = scope.panel.uuidString
        }
        if method == "system.tree" {
            params["scope"] = "workspace"
            params.removeValue(forKey: "all_windows")
        }
        if method == "system.identify" || method == "system.tree" {
            params["caller"] = ["panel_id": scope.panel.uuidString, "workspace_id": scope.workspace.uuidString]
        }
        return params
    }

    /// A v1 sidebar write rebuilt from the same tokens its handler reads:
    /// every target option the caller wrote (and its space-separated value)
    /// is dropped, the rest is re-quoted exactly, and c11's own
    /// `--tab=<the panel's workspace> --panel=<the panel>` lead. No parser
    /// difference can hide another target, and a handler never falls back
    /// to the selected workspace or the focused panel.
    static func scopedV1Line(_ line: String, command: String, caller: VerifiedCaller) -> Result<String, Refusal> {
        guard let workspace = caller.workspace else { return .failure(targetRefusal(command)) }
        return .success(rebuiltV1Line(line, command: command,
                                      lead: ["--tab=\(workspace.uuidString)", "--panel=\(caller.panel.uuidString)"]))
    }

    /// C11H-371: a v1 read (`list_status`, `list_log`) rebuilt the same way,
    /// led by `--tab=<the caller's workspace>`, so it never lists another one.
    static func scopedV1Read(_ line: String, command: String, caller: VerifiedCaller) -> Result<String, Refusal> {
        guard let scope = caller.readScope else { return .failure(readScopeRefusal) }
        return .success(rebuiltV1Line(line, command: command, lead: ["--tab=\(scope.workspace.uuidString)"]))
    }

    private static func rebuiltV1Line(_ line: String, command: String, lead own: [String]) -> String {
        let rest = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let tokens = TerminalController.tokenizeArgsStatic(rest)
        var kept: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--"), token != "--" {
                let body = token.dropFirst(2)
                let key = (body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "").lowercased()
                if v1TargetOptions.contains(key) {
                    if !body.contains("="), index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") { index += 1 }
                    index += 1
                    continue
                }
            }
            kept.append(token)
            index += 1
        }
        return ([command] + (own + kept).map(quotedV1Token)).joined(separator: " ")
    }

    /// C11H-360 (hardening): a relayed sidebar write never names c11's own
    /// `remote.*` status keys or a log source c11 writes about the link
    /// (`remote`, `remote-proxy`, `remote-daemon`, `remote-forward`: `remote`
    /// or any `remote-` source). `line` is the scoped line the handler will
    /// read, walked with the handler's own tokenizer and option walker.
    static func sidebarWriteRefusal(_ line: String, command: String) -> Refusal? {
        let rest = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let parsed = TerminalController.walkOptions(TerminalController.tokenizeArgsStatic(rest),
                                                    stopAtDashes: !TerminalController.v1OptionsReadPastDashes.contains(command))
        if command == "set_status" || command == "clear_status",
           let key = parsed.positional.first, foldedIdentity(key).hasPrefix(reservedSidebarPrefix) {
            return keyReservedRefusal(command)
        }
        if command == "log", let source = parsed.options["source"], isReservedLogSource(source) {
            return keyReservedRefusal(command)
        }
        return nil
    }

    static func isReservedLogSource(_ source: String) -> Bool {
        let folded = foldedIdentity(source)
        return folded == reservedLogSource || folded.hasPrefix(reservedLogSource + "-")
    }

    /// One token in the form `tokenizeArgsStatic` reads back unchanged.
    static func quotedV1Token(_ token: String) -> String {
        var out = "\""
        for character in token {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return out + "\""
    }

    /// `identityTaken(value, caller)`: whether a live panel other than the
    /// caller answers to `value` as its mail address, role or title.
    static func admit(_ request: C11Relay.Request, caller: VerifiedCaller,
                      identityTaken: (String, UUID) -> Bool = { _, _ in false }) -> Result<Admitted, Refusal> {
        switch request.framing {
        case .text:
            let command = request.line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            guard v1Commands.contains(command) else { return .failure(notAllowed(command.isEmpty ? "?" : command)) }
            if v1Reads.contains(command) {
                switch scopedV1Read(request.line, command: command, caller: caller) {
                case .failure(let refusal): return .failure(refusal)
                case .success(let line): return .success(.v1(command: command, line: line))
                }
            }
            guard v1Writes.contains(command) else { return .success(.v1(command: command, line: request.line)) }
            switch scopedV1Line(request.line, command: command, caller: caller) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let line):
                // C11H-360: checked on the line the handler reads, after the
                // caller's own target options are gone.
                if let refusal = sidebarWriteRefusal(line, command: command) { return .failure(refusal) }
                return .success(.v1(command: command, line: line))
            }
        case .json:
            guard let data = request.line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let method = object["method"] as? String else {
                return .failure(Refusal(code: "invalid_request", message: "The relayed request is not a v2 JSON line."))
            }
            var params = object["params"] as? [String: Any] ?? [:]
            guard v2Methods.contains(method) || C11RelayMethods.all.contains(method) || showMethods.contains(method) else {
                return .failure(notAllowed(method))
            }
            // C11H-228: a show names no target at all; c11 places it beside
            // the verified caller and reads the caller's own machine.
            if showMethods.contains(method) {
                for key in params.keys where panelTargetKeys.contains(key) || workspaceTargetKeys.contains(key)
                    || isOtherTargetKey(key) || showForbiddenKeys.contains(key) {
                    return .failure(targetRefusal(method))
                }
            }
            // A journal event names its panel itself (`tab_id`, or the `panel_id`
            // alias): it must be the verified caller, never another panel.
            if method == "agent.event.append" {
                let event = params["event"] as? [String: Any] ?? [:]
                let named = ["tab_id", "panel_id"].compactMap { event[$0] }
                guard !named.isEmpty, named.allSatisfy({ ($0 as? String).flatMap(UUID.init(uuidString:)) == caller.panel }) else {
                    return .failure(journalPanelRefusal)
                }
                // C11H-134: `interactive_pid` names a process on the calling
                // machine. c11 checks it against its own processes, where it
                // means nothing and could match an unrelated one.
                params.removeValue(forKey: "interactive_pid")
            }
            if method == "panel.action" {
                let action = (params["action"] as? String)?.lowercased() ?? ""
                guard panelActions.contains(action) else { return .failure(notAllowed("panel.action \(action)")) }
            }
            switch scopedParams(params, method: method, caller: caller, claimedWorkspace: request.workspace) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let scoped): params = scoped
            }
            if method == "notification.create_for_panel" {
                for key in notificationLocalKeys { params.removeValue(forKey: key) }
            }
            // A relayed flag is the agent's, never the operator's.
            if method == "flag.raise" || method == "flag.lower" { params["by"] = "agent" }
            // A panel cannot take another live panel's mail identity, nor one
            // c11 itself speaks as (C11H-360).
            if method == "panel.set_metadata", let metadata = params["metadata"] as? [String: Any] {
                for key in mailboxIdentityKeys {
                    guard let value = (metadata[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
                    if isReservedIdentity(value) { return .failure(identityReservedRefusal(value)) }
                    if identityTaken(value, caller.panel) { return .failure(identityTakenRefusal(value)) }
                }
            }
            // C11H-360: c11's own workspace keys stay c11's.
            if workspaceScopedWrites.contains(method), let refusal = workspaceWriteRefusal(params, method: method) {
                return .failure(refusal)
            }
            // Attribution always names the verified caller, never what the request said.
            let hadCaller = callerKeys.contains { params[$0] != nil }
            for key in callerKeys { params.removeValue(forKey: key) }
            if hadCaller || method == "flag.raise" || method == "flag.lower" {
                params["caller_panel_id"] = caller.panel.uuidString
            }
            if var block = params["caller"] as? [String: Any], block["panel_id"] != nil {
                block["panel_id"] = caller.panel.uuidString
                params["caller"] = block
            }
            var rewritten = object
            rewritten["params"] = params
            guard let encoded = try? JSONSerialization.data(withJSONObject: rewritten),
                  let line = String(data: encoded, encoding: .utf8) else {
                return .failure(Refusal(code: "invalid_request", message: "The relayed request could not be encoded."))
            }
            return .success(.v2(method: method, id: object["id"], params: params, line: line))
        }
    }

    /// C11H-123: a journal event from a terminal on another machine names
    /// its own panel (checked in `admit`) but cannot know that panel's journal
    /// owner, the opaque hc identity c11 derives for the terminal
    /// (`HCRemoteStatus.owner`). An event with no session id (absent, or null
    /// as the CLI's canonical encoding sends it) is attributed to that owner
    /// when the agent kinds match; any other event passes as it
    /// is, and the journal's own owner check still decides.
    static func attributingJournalEvent(_ admitted: Admitted, hcOwner: JournalOwner?) -> Admitted {
        guard case .v2(let method, let id, var params, let line) = admitted, method == "agent.event.append",
              let owner = hcOwner, owner.sessionID.hasPrefix("hc-"),
              var event = params["event"] as? [String: Any], event["session_id"] == nil || event["session_id"] is NSNull,
              event["agent_kind"] as? String == owner.agentKind,
              let named = (event["tab_id"] ?? event["panel_id"]) as? String,
              UUID(uuidString: named) == owner.panelID,
              let data = line.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return admitted }
        event["session_id"] = owner.sessionID
        params["event"] = event
        object["params"] = params
        guard let encoded = try? JSONSerialization.data(withJSONObject: object),
              let rewritten = String(data: encoded, encoding: .utf8) else { return admitted }
        return .v2(method: method, id: id, params: params, line: rewritten)
    }

    /// A v2 error reply for a refused relayed request, or a v1 `ERROR:` line.
    static func reply(for refusal: Refusal, framing: C11Relay.Framing, line: String) -> String {
        switch framing {
        case .text:
            return "ERROR: \(refusal.code): \(refusal.message)"
        case .json:
            let id = line.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["id"]
            return v2Reply(id: id, error: refusal)
        }
    }

    static func v2Reply(id: Any?, result: [String: Any]) -> String {
        encode(["id": id ?? NSNull(), "ok": true, "result": result])
    }

    static func v2Reply(id: Any?, error: Refusal) -> String {
        encode(["id": id ?? NSNull(), "ok": false, "error": ["code": error.code, "message": error.message]])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"ok":false,"error":{"code":"internal","message":"encoding failed"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
