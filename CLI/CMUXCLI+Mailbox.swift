// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

// MARK: - C11-13 Stage 2: `c11 mailbox` subcommand
//
// Pure file-I/O wrappers around MailboxEnvelope + MailboxIO + MailboxLayout.
// One socket call in practice: `surface.get_metadata` to resolve the caller's
// surface title. Raw-bash writers use the outbox-dir / inbox-dir / surface-name
// helpers to avoid any c11-provided env vars.

extension CMUXCLI {

    func runMessagesCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard let sub = commandArgs.first else {
            print(messagesUsage())
            return
        }
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "help", "-h", "--help":
            print(messagesUsage())
        case "view":
            var params: [String: Any] = [:]
            if let workspaceRaw = optionValue(rest, name: "--workspace") {
                params["workspace_id"] = try resolveWorkspaceId(workspaceRaw, client: client)
            } else {
                // `messages.view` is non-focus-intent. Carry the invoking
                // c11 tab's workspace so the app can open the page there
                // without selecting the operator's currently visible one.
                let environment = ProcessInfo.processInfo.environment
                let callerWorkspace = environment["C11_WORKSPACE_ID"]
                    ?? environment["CMUX_WORKSPACE_ID"]
                if let callerWorkspace,
                   let workspaceID = UUID(uuidString: callerWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    params["workspace_id"] = workspaceID.uuidString
                }
            }
            try addCallingPanel(to: &params)
            let payload = try client.sendV2(method: "messages.view", params: params)
            printV2Payload(
                payload,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                fallbackText: "Opened c11 messages page"
            )
        default:
            throw CLIError(message: "unknown messages subcommand '\(sub)'. Use `c11 messages help` for usage.")
        }
    }

    func messagesUsage() -> String {
        """
        c11 messages — live agent traffic

        Open the self-contained local page that renders explicit `c11 send`
        events and durable mailbox traffic. The page is written under c11's
        Application Support state directory and does not start a server.

          view                 open or refresh the messages browser panel

        View flags:
          --workspace <ref>    target a workspace (default: caller workspace)

        Alias:
          c11 mailbox view
        """
    }

    func runMailboxCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let sub = commandArgs.first else {
            print(mailboxUsage())
            return
        }
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "help", "-h", "--help":
            print(mailboxUsage())
        case "send":
            try runMailboxSendCommand(subArgs: rest, client: client, jsonOutput: jsonOutput)
        case "recv":
            try runMailboxRecvCommand(subArgs: rest, client: client, jsonOutput: jsonOutput)
        case "view":
            try runMessagesCommand(
                commandArgs: ["view"] + rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: .refs
            )
        case "trace":
            try runMailboxTraceCommand(subArgs: rest, client: client, jsonOutput: jsonOutput)
        case "status":
            try runMailboxStatusCommand(subArgs: rest, jsonOutput: jsonOutput)
        case "tail":
            try runMailboxTailCommand(subArgs: rest, client: client, jsonOutput: jsonOutput)
        case "outbox-dir":
            try runMailboxOutboxDirCommand(subArgs: rest, client: client)
        case "inbox-dir":
            try runMailboxInboxDirCommand(subArgs: rest, client: client)
        case "panel-name", "tab-name", "surface-name":
            try runMailboxSurfaceNameCommand(subArgs: rest, client: client)
        case "sender-from":
            try runMailboxSenderFromCommand(subArgs: rest, client: client)
        case "new-id":
            print(MailboxULID.make())
        case "watch":
            throw CLIError(message: "watch not implemented in Stage 2; see c11 mailbox tail for the log-follow equivalent")
        default:
            throw CLIError(message: "unknown mailbox subcommand '\(sub)'. Use `c11 mailbox help` for usage.")
        }
    }

    func mailboxUsage() -> String {
        """
        c11 mailbox — inter-agent messaging

        Per-workspace messaging primitive for coordinating between c11 panels.
        Full guide: docs/c11-mailbox-guide.md (agent quick-reference: skills/c11/SKILL.md).

          send       deliver an envelope to a panel in any workspace
          recv       drain or peek the caller's inbox
          view       open or refresh the live messages page
          trace      pretty-print _dispatch.log lines for an envelope id
          status     sent, delivered and read per recipient for an envelope id
          tail       follow _dispatch.log
          outbox-dir print the caller's outbox directory (for raw-bash writers)
          inbox-dir  print the caller's inbox directory (for raw-bash readers)
          panel-name  print the caller's display title
          sender-from print the caller's default envelope `from` value
          new-id     print a fresh Crockford base32 ULID (26 chars)

        Send flags:
          --to <panel>            recipient panel name (any workspace)
          --to-parent             send to this panel's direct parent by exact UUID
          --to-workspace <ref>    disambiguate a name shared across workspaces
          --topic <topic>         dotted topic token
          --body <text>           inline body (≤ 4096 bytes UTF-8)
          <text>                  one trailing argument, the body, when --body is absent
          --body-ref <path>       absolute path to external body (body must be empty)
          --reply-to <panel>      panel that should receive the reply
          --in-reply-to <ulid>    envelope id this is replying to
          --urgent                sender hint (handlers may ignore)
          --ttl-seconds <n>       advisory expiry
          --from <value>          override the envelope's sender value
          --id <ulid>             pin envelope id (testing / replay)
          --ts <rfc3339>          pin timestamp (testing / replay)
          --content-type <mime>   MIME hint for body or body_ref

          An empty body with no --body-ref is an error. --body together with a
          trailing argument, a second trailing argument, and unknown flags are
          errors. Nothing is sent. --body takes the next token as text, even
          when that token starts with dashes. -- before a trailing argument
          does the same. mailbox send --help still prints this help.

        Recv flags:
          --drain                 default — print each message and move it to _read/
          --peek                  list + print only
          --ack                   mark read even when stdout is not a terminal.
                                  A tool call's stdout is a pipe: pass --ack.
          --hook-format <h>       claude | codex | grok: print that harness's Stop-hook JSON
                                  (turn-end drain; event from hook stdin or --event).
                                  Pass --ack: a hook has no terminal.
          --event <e>             stop (with --hook-format; other events never drain)
          --panel <name>          override caller's resolved panel

          A drain marks mail read only when stdout is a terminal or --ack is
          passed. Otherwise it exits nonzero and leaves the inbox unchanged.
          The error repeats the command you ran and adds --ack, so --socket,
          --window, --panel, --tab, and --surface stay.
        """
    }

    // MARK: - Caller resolution

    /// Returns the caller's workspace UUID, panel title, panel UUID and
    /// mailbox address. The panel UUID (C11_PANEL_ID) is the identity, and
    /// `panel.get_metadata` returns its title and its live workspace.
    /// C11_WORKSPACE_ID is only where the shell started: a panel moved since
    /// then keeps the old value (C11-491), so it is used only when c11 does
    /// not report a workspace. The legacy environment aliases remain fallbacks.
    /// Pass an override when scripting without a live c11 panel; its UUID is
    /// then the override itself when it is a UUID, else nil, and the
    /// workspace is the environment's.
    /// Inboxes are keyed on the panel UUID; sender-from chooses between the
    /// existing title and exact UUID form using the mailbox address.
    func resolveMailboxCaller(
        client: SocketClient,
        fromOverride: String?,
        surfaceOverride: String?
    ) throws -> (workspaceId: UUID, panelName: String, panelId: UUID?, mailboxAddress: String?) {
        let env = ProcessInfo.processInfo.environment
        let envWorkspaceId = Self.envWorkspaceId(env)
        let workspaceNotSet = CLIError(
            message: String(
                localized: "mailbox.cli.error.workspace-not-set",
                defaultValue: "C11_WORKSPACE_ID is not set. Run from a c11 panel or set it for a script."
            )
        )

        if let name = fromOverride ?? surfaceOverride, !name.isEmpty {
            // A `--panel` UUID or ref names one panel app-wide: take its live
            // workspace and title from c11 rather than matching it as a name
            // in the caller's workspace (C11-491).
            // A ref names only a live panel, so an unknown one is an error
            // (the app's `not_found`), never an empty inbox. A UUID may name a
            // closed panel's retained inbox and falls back to the name path.
            let isPanelRef = isHandleRef(name)
                && ["panel:", "tab:", "surface:"].contains(where: name.lowercased().hasPrefix)
            if fromOverride == nil, isPanelRef || isUUID(name) {
                let payload: [String: Any]?
                if isPanelRef {
                    payload = try client.sendV2(method: "panel.get_metadata", params: ["panel_id": name])
                } else {
                    payload = try? client.sendV2(method: "panel.get_metadata", params: ["panel_id": name])
                }
                if let payload,
                   let panelId = ((payload["panel_id"] ?? payload["surface_id"]) as? String).flatMap(UUID.init(uuidString:)),
                   let workspaceId = (payload["workspace_id"] as? String).flatMap(UUID.init(uuidString:)) {
                    let metadata = (payload["metadata"] as? [String: Any]) ?? [:]
                    let title = (metadata["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? panelId.uuidString
                    return (workspaceId, title, panelId, metadata["mailbox.address"] as? String)
                }
            }
            guard let envWorkspaceId else { throw workspaceNotSet }
            return (envWorkspaceId, name, UUID(uuidString: name), nil)
        }

        let surfaceIdStr = Self.callerPanelEnv(env)
        guard let surfaceIdStr, let surfaceId = UUID(uuidString: surfaceIdStr) else {
            guard envWorkspaceId != nil else { throw workspaceNotSet }
            throw CLIError(message: "C11_PANEL_ID not set — pass --from <panel> to override")
        }

        let payload: [String: Any]
        do {
            payload = try client.sendV2(
                method: "panel.get_metadata",
                params: ["panel_id": surfaceIdStr]
            )
        } catch let error as CLIError
            where error.message.hasPrefix("not_found:") || error.message.hasPrefix("surface_not_found:") {
            // An unknown panel UUID is refused before lookup (`not_found`).
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.error.caller-not-open",
                    defaultValue: "Your panel %@ (`C11_PANEL_ID`) is not open in c11, in any workspace."
                ).replacingOccurrences(of: "%@", with: surfaceIdStr)
            )
        }
        guard let workspaceId = (payload["workspace_id"] as? String).flatMap(UUID.init(uuidString:))
            ?? envWorkspaceId else { throw workspaceNotSet }
        let metadata = (payload["metadata"] as? [String: Any]) ?? [:]
        guard let title = metadata["title"] as? String, !title.isEmpty else {
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.error.caller-untitled",
                    defaultValue: "Your panel %@ (`C11_PANEL_ID`) has no title. Name it with `c11 rename-panel`, or pass `--from <name>`."
                ).replacingOccurrences(of: "%@", with: surfaceIdStr)
            )
        }
        let mailboxAddress = metadata["mailbox.address"] as? String
        return (workspaceId, title, surfaceId, mailboxAddress)
    }

    /// C11_WORKSPACE_ID, or its legacy alias: where the caller's shell started.
    static func envWorkspaceId(_ env: [String: String]) -> UUID? {
        (env["C11_WORKSPACE_ID"] ?? env["CMUX_WORKSPACE_ID"]).flatMap(UUID.init(uuidString:))
    }

    /// The tab UUID whose inbox `recv` / `inbox-dir` should read. A caller
    /// without an override already knows it; a `--surface <name>` override is
    /// resolved through `mailbox.resolve` in the caller's workspace. `nil` when
    /// the name matches no single live tab (or c11 is unreachable): only the
    /// legacy title-keyed inbox is then readable.
    func resolveMailboxInboxPanelId(
        client: SocketClient,
        workspaceId: UUID,
        panelName: String,
        panelId: UUID?
    ) -> UUID? {
        if let panelId { return panelId }
        guard let payload = try? client.sendV2(
            method: "mailbox.resolve",
            params: [
                "to": panelName,
                "sender_workspace_id": workspaceId.uuidString,
                "workspace": workspaceId.uuidString
            ]
        ),
            (payload["resolution"] as? String) == "unique",
            let ids = (payload["panel_ids"] ?? payload["tab_ids"] ?? payload["surface_ids"]) as? [String],
            ids.count == 1 else {
            return nil
        }
        return UUID(uuidString: ids[0])
    }

    // MARK: - send

    func runMailboxSendCommand(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        // Parse before any socket call or outbox write. A bad argv must exit
        // nonzero with nothing sent (C11-364).
        let parsed: MailboxSendArguments.Parsed
        do {
            parsed = try MailboxSendArguments.parse(subArgs)
        } catch let failure as MailboxSendArguments.Failure {
            throw CLIError(message: failure.description)
        }
        let reportJSON = jsonOutput || parsed.json
        var to = parsed.to
        let topic = parsed.topic
        let body = parsed.body
        let bodyRef = parsed.bodyRef
        let replyTo = parsed.replyTo
        let inReplyTo = parsed.inReplyTo
        let urgent = parsed.urgent
        let ttlSeconds = parsed.ttlSeconds.flatMap(Int.init)
        let idOverride = parsed.id
        let tsOverride = parsed.ts
        let contentType = parsed.contentType
        let fromOverride = parsed.from
        var toWorkspace = parsed.toWorkspace

        if parsed.toParent {
            let parent = try resolveMailboxParent(client: client)
            to = "id:\(parent.panelId.uuidString)"
            toWorkspace = parent.workspaceId.uuidString
        }

        if to == nil && topic == nil {
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.error.no-recipient",
                    defaultValue: "A mailbox envelope needs --to or --topic."
                )
            )
        }

        // Stage 2 does not implement topic subscribe / fan-out. A topic-only
        // envelope would resolve to an empty recipient list and silently
        // vanish — reject at the CLI boundary so the operator sees the
        // failure instead of losing the message. Tracked for Stage 3;
        // pair with --to <surface> until then.
        if to == nil && topic != nil {
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.error.topics-not-implemented",
                    defaultValue: "Topic-only envelopes are not delivered in Stage 2 (topic subscribe/fan-out ships in Stage 3). Pair --topic with --to <panel-name> to send now."
                )
            )
        }

        if Data(body.utf8).count > MailboxEnvelope.maxBodyBytes {
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.error.body-too-large",
                    defaultValue: "Inline --body exceeds the 4 KB cap. Use --body-ref <path> for larger payloads."
                )
            )
        }

        let (workspaceId, panelName, callerPanelId, mailboxAddress) = try resolveMailboxCaller(
            client: client,
            fromOverride: fromOverride,
            surfaceOverride: nil
        )

        guard let from = MailboxSenderFrom.value(
            override: fromOverride,
            title: panelName,
            mailboxAddress: mailboxAddress,
            panelId: callerPanelId
        ) else {
            throw CLIError(message: "C11_PANEL_ID not set — pass --from <panel> to override")
        }
        let envelope = try MailboxEnvelope.build(
            from: from,
            to: to,
            topic: topic,
            body: body,
            id: idOverride,
            ts: tsOverride,
            replyTo: replyTo,
            inReplyTo: inReplyTo,
            urgent: urgent ? true : nil,
            ttlSeconds: ttlSeconds,
            bodyRef: bodyRef,
            contentType: contentType,
            // The exact calling panel, for the drawer's Sent view (C11-399).
            // Not sent with a --from override: that names someone else.
            ext: (fromOverride == nil) ? callerPanelId.map {
                MailboxEnvelope.senderClaim(panel: $0, workspace: workspaceId)
            } : nil
        )

        // Resolve which workspace actually hosts the recipient. The dispatcher
        // is per-workspace, so the envelope must land in the recipient's outbox
        // — which may be a different workspace than the sender's. Resolution
        // also lets us fail loudly (non-zero exit) when the recipient does not
        // exist, instead of dropping the message into an outbox where no
        // dispatcher will ever resolve it. `to` is guaranteed non-nil here
        // (topic-only sends were rejected above).
        let resolution = try resolveMailboxTargetWorkspace(
            client: client,
            to: to ?? "",
            senderWorkspaceId: workspaceId,
            qualifier: toWorkspace,
            requireVerified: parsed.toParent
        )
        let targetWorkspaceId = resolution.workspaceId

        let stateURL = try MailboxLayout.defaultStateURL()
        let outboxURL = MailboxLayout.outboxURL(state: stateURL, workspaceId: targetWorkspaceId)
        try FileManager.default.createDirectory(
            at: outboxURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let targetURL = outboxURL.appendingPathComponent(
            MailboxLayout.envelopeFilename(id: envelope.id)
        )
        let data = try envelope.encode()
        try MailboxIO.atomicWrite(data: data, to: targetURL)

        // The recipient could not be resolved across workspaces (c11
        // unreachable). The envelope was written best-effort to the sender's
        // own workspace — a same-workspace recipient still gets it, otherwise
        // the dispatcher rejects it. Either way the operator must know the send
        // was unverified, so fail loud and non-zero instead of printing the id
        // as if it succeeded.
        if !resolution.verified {
            var message = String(
                localized: "mailbox.cli.error.unverified-send",
                defaultValue: "c11 unreachable: wrote envelope %@ to your own workspace but could not verify recipient \"%@\" across workspaces. If the recipient is not in your workspace the message will be rejected — run `c11 mailbox trace %@` to confirm delivery."
            )
            // Fill the three %@ placeholders left-to-right: id, recipient, id.
            for value in [envelope.id, to ?? "", envelope.id] {
                if let range = message.range(of: "%@") {
                    message.replaceSubrange(range, with: value)
                }
            }
            throw CLIError(message: message)
        }

        if reportJSON {
            print(jsonString([
                "id": envelope.id,
                "outbox_path": targetURL.path,
                "workspace_id": targetWorkspaceId.uuidString,
                "sender_workspace_id": workspaceId.uuidString,
                "from": envelope.from,
                "requested_recipient": to ?? "",
                "recipients": resolution.recipients
            ]))
        } else {
            print(envelope.id)
            for recipient in resolution.recipients {
                let owner = recipient["name"] as? String ?? recipient["panel_id"] as? String ?? ""
                if let requestedID = recipient["requested_panel_id"] as? String,
                   let actualID = recipient["panel_id"] as? String, requestedID != actualID {
                    let notice = String(format: String(localized: "mailbox.cli.shared-owner",
                        defaultValue: "Mail to %@ uses the shared OpenCode inbox of %@ (%@)."), to ?? "", owner, actualID)
                    FileHandle.standardError.write(Data((notice + "\n").utf8))
                }
                if recipient["can_ring"] as? Bool == false {
                    let reason = recipient["doorbell_unavailable_reason"] as? String ?? "unavailable"
                    let notice = String(format: String(localized: "mailbox.cli.cannot-ring",
                        defaultValue: "Mail is queued for %@, but c11 cannot ring its harness (%@). Use c11 mailbox recv --ack to read it."), owner, reason)
                    FileHandle.standardError.write(Data((notice + "\n").utf8))
                }
            }
        }
    }

    func resolveMailboxParent(client: SocketClient) throws -> (panelId: UUID, workspaceId: UUID) {
        guard let callerRaw = try resolveCallingSurface(environment: ProcessInfo.processInfo.environment),
              let callerId = UUID(uuidString: callerRaw) else {
            throw CLIError(message: String(localized: "mailbox.cli.error.to-parent-no-caller", defaultValue: "mailbox send --to-parent needs C11_PANEL_ID from a child panel."))
        }

        let family: [String: Any]
        do {
            family = try client.sendV2(method: "panel.family", params: ["panel_id": callerId.uuidString])
        } catch let error as CLIError where error.message.contains("method_not_found") {
            throw CLIError(message: String(localized: "mailbox.cli.error.to-parent-unsupported", defaultValue: "mailbox send --to-parent requires an updated c11 app and CLI with panel.family support."))
        }

        let nodes = family["nodes"] as? [[String: Any]] ?? []
        guard let caller = nodes.first(where: { UUID(uuidString: $0["id"] as? String ?? "") == callerId }),
              let parentRaw = caller["parent_panel_id"] as? String,
              let parentId = UUID(uuidString: parentRaw),
              let parent = nodes.first(where: { UUID(uuidString: $0["id"] as? String ?? "") == parentId }),
              let workspaceRaw = parent["workspace_id"] as? String,
              let workspaceId = UUID(uuidString: workspaceRaw) else {
            throw CLIError(message: String(localized: "mailbox.cli.error.to-parent-none", defaultValue: "This panel has no known parent; --to-parent requires a child panel."))
        }
        guard (parent["state"] as? String) == "live" else {
            let title = parent["title"] as? String ?? parentId.uuidString
            throw CLIError(message: String(localized: "mailbox.cli.error.to-parent-closed", defaultValue: "Parent panel \(title) is closed, so --to-parent cannot deliver."))
        }
        return (parentId, workspaceId)
    }

    /// Resolves which workspace's outbox a `--to` envelope should be written
    /// into by asking the app for a cross-workspace view of live surfaces
    /// (`mailbox.resolve`). Throws a non-zero `CLIError` when the recipient is
    /// unknown (so the sender learns the message was not delivered) or when the
    /// name is ambiguous across workspaces. Falls back to the sender's own
    /// workspace if the socket is unreachable, so same-workspace delivery still
    /// works offline; the dispatcher's unresolved-recipient rejection is the
    /// backstop against a silent drop in that case.
    func resolveMailboxTargetWorkspace(
        client: SocketClient,
        to: String,
        senderWorkspaceId: UUID,
        qualifier: String?,
        requireVerified: Bool = false
    ) throws -> (workspaceId: UUID, verified: Bool, recipients: [[String: Any]]) {
        var params: [String: Any] = [
            "to": to,
            "sender_workspace_id": senderWorkspaceId.uuidString
        ]
        if let qualifier, !qualifier.isEmpty {
            params["workspace"] = qualifier
        }

        let payload: [String: Any]
        do {
            payload = try client.sendV2(method: "mailbox.resolve", params: params)
        } catch {
            if requireVerified {
                throw CLIError(message: String(
                    localized: "mailbox.cli.error.to-parent-unverified",
                    defaultValue: "mailbox send --to-parent could not verify the exact parent panel; no envelope was written."
                ))
            }
            // Socket unreachable (or an older app without mailbox.resolve): we
            // cannot resolve across workspaces. Fall back to the sender's own
            // workspace so a same-workspace recipient still gets the message,
            // but flag it `verified: false` so the caller warns loudly and
            // exits non-zero — an unverified send must not look like success.
            return (senderWorkspaceId, false, [])
        }

        switch payload["resolution"] as? String {
        case "unique":
            guard
                let idStr = payload["target_workspace_id"] as? String,
                let id = UUID(uuidString: idStr)
            else {
                throw CLIError(message: "mailbox.resolve returned an invalid target workspace")
            }
            return (id, true, payload["recipients"] as? [[String: Any]] ?? [])
        case "ambiguous":
            let candidates = (payload["candidates"] as? [[String: Any]]) ?? []
            throw CLIError(message: mailboxAmbiguityMessage(to: to, candidates: candidates))
        default:
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.error.unresolved-recipient",
                    defaultValue: "No live panel named \"%@\" in any workspace. Message not sent."
                ).replacingOccurrences(of: "%@", with: to)
            )
        }
    }

    func mailboxAmbiguityMessage(to: String, candidates: [[String: Any]]) -> String {
        var seenRefs: Set<String> = []
        var refLines: [String] = []
        for candidate in candidates {
            guard let ref = candidate["workspace_ref"] as? String else { continue }
            if seenRefs.insert(ref).inserted {
                refLines.append("  \(ref)")
            }
        }
        let header = String(
            localized: "mailbox.cli.error.ambiguous-header",
            defaultValue: "Panel \"%@\" exists in more than one workspace:"
        ).replacingOccurrences(of: "%@", with: to)
        let hint = String(
            localized: "mailbox.cli.error.ambiguous-hint",
            defaultValue: "Disambiguate with --to-workspace <workspace-ref>."
        )
        return ([header] + refLines + [hint]).joined(separator: "\n")
    }

    // MARK: - recv

    func runMailboxRecvCommand(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let parsed: MailboxRecvArguments.Parsed
        do {
            parsed = try MailboxRecvArguments.parse(subArgs)
        } catch let failure as MailboxRecvArguments.Failure {
            throw CLIError(message: failure.description)
        }
        if let rawFormat = parsed.hookFormat {
            // A hook has no terminal. It marks mail read only when the caller
            // passed --ack (or stdout really is a terminal). Missing --ack
            // claims nothing and still exits 0: a hook must not fail the harness.
            let acknowledged = MailboxRecvAdmission.allowsMarkRead(
                stdoutIsTTY: isatty(STDOUT_FILENO) != 0,
                acknowledged: parsed.ack
            )
            runMailboxHookRecv(
                rawFormat: rawFormat,
                subArgs: subArgs,
                client: client,
                acknowledged: acknowledged
            )
            return
        }
        let peek = parsed.peek
        let drain = parsed.drains
        let surfaceOverride = parsed.panel

        let (workspaceId, panelName, callerPanelId, _) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: surfaceOverride
        )
        let panelId = resolveMailboxInboxPanelId(
            client: client,
            workspaceId: workspaceId,
            panelName: panelName,
            panelId: callerPanelId
        )

        // The UUID-keyed inbox plus, when one exists on disk, the title-keyed
        // inbox an older build wrote, merged in ULID (send) order.
        let stateURL = try MailboxLayout.defaultStateURL()
        var inboxURLs = MailboxLayout.recvInboxURLs(
            state: stateURL,
            workspaceId: workspaceId,
            panelId: panelId,
            panelName: panelName
        )
        var sharedInboxRecipients: [URL: (id: UUID, name: String)] = [:]
        // Authenticated duplicate views share the owner's inbox. Include
        // the live views' prior inboxes as well, so mail received before the
        // conflict was captured remains readable from either agent environment.
        if let panelId {
            var params: [String: Any] = ["to": "id:\(panelId.uuidString)", "sender_workspace_id": workspaceId.uuidString]
            if surfaceOverride == nil, let session = ProcessInfo.processInfo.environment["OPENCODE_SESSION_ID"] {
                params["opencode_session_id"] = session
            }
            let resolution: [String: Any]?
            do { resolution = try client.sendV2(method: "mailbox.resolve", params: params) }
            catch { resolution = nil } // Older/offline apps retain ordinary local recv.
            let recipients = resolution?["recipients"] as? [[String: Any]] ?? []
            for recipient in recipients {
                for inbox in recipient["shared_inboxes"] as? [[String: String]] ?? [] {
                    guard let id = inbox["panel_id"].flatMap(UUID.init(uuidString:)),
                          let ws = inbox["workspace_id"].flatMap(UUID.init(uuidString:)) else { continue }
                    let sharedURLs = MailboxLayout.recvInboxURLs(state: stateURL, workspaceId: ws,
                                                                panelId: id, panelName: inbox["name"] ?? "")
                    for url in sharedURLs {
                        sharedInboxRecipients[url.standardizedFileURL] = (id, inbox["name"] ?? panelName)
                        if !inboxURLs.contains(url) { inboxURLs.append(url) }
                    }
                }
            }
        }
        // C11-491: mail delivered before a move stays in the inbox of each
        // workspace the panel passed through, so a moved panel reads them all.
        // The caller's own panel moved when its start workspace is not its
        // live one; another panel's history is unknown, so its are searched.
        let startWorkspaceId = Self.envWorkspaceId(ProcessInfo.processInfo.environment)
        if let panelId, surfaceOverride != nil || (startWorkspaceId != nil && startWorkspaceId != workspaceId) {
            let retained = MailboxDrain.panelInboxURLs(
                workspacesRoot: stateURL.appendingPathComponent(MailboxLayout.workspacesDirectoryName, isDirectory: true),
                preferredWorkspaceId: surfaceOverride == nil ? startWorkspaceId : workspaceId,
                currentWorkspaceId: surfaceOverride == nil ? workspaceId : nil,
                scanWhenOwnerUnknown: true,
                panelId: panelId
            )
            for inbox in retained
            where !inboxURLs.contains(where: { $0.standardizedFileURL == inbox.standardizedFileURL }) {
                inboxURLs.append(inbox)
            }
        }
        guard drain else {
            let entries = inboxURLs
                .flatMap { MailboxDrain.pendingEntries(inbox: $0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in entries {
                let data = try Data(contentsOf: url)
                print(MailboxFraming.displayText(data: data))
            }
            return
        }

        // C11-257 C3: claim one envelope, write it, then the next, across the
        // UUID inbox and any legacy title inbox merged in ULID order (as peek
        // prints them). A failed write (closed pipe, full disk) puts that
        // envelope back and stops, so nothing reaches `_read/` unless it
        // reached stdout.
        signal(SIGPIPE, SIG_IGN)
        let claimed: [MailboxDrain.ClaimedMessage]
        do {
            claimed = try MailboxRecvAdmission.consume(
                inboxes: inboxURLs,
                stdoutIsTTY: isatty(STDOUT_FILENO) != 0,
                acknowledged: parsed.ack,
                retryCommand: MailboxRecvAdmission.retryCommand(
                    arguments: CommandLine.arguments
                )
            ) { message in
                let shown = MailboxFraming.displayText(data: Data(message.text.utf8))
                return Self.writeStdout(shown + "\n")
            }.claimed
        } catch let refusal as MailboxRecvAdmission.Refusal {
            throw CLIError(message: refusal.description)
        }
        // `tabId` is the recipient's: the caller's own without `--tab`, the
        // override's resolved UUID with it, nil when a `--tab` name matched no
        // single live tab (the event then carries no surface rather than the
        // caller's).
        // A shared drain can claim files owned by more than one panel. Each
        // receipt names the inbox actually claimed, not the tool's inherited
        // panel environment, so the drawer and delivery journal agree.
        if sharedInboxRecipients.isEmpty {
            writeDeliveryReceipts(claimed, recipientPanelId: panelId, via: "recv", recipient: { _ in panelName })
        } else {
            for (inbox, messages) in Dictionary(grouping: claimed, by: { $0.inbox.standardizedFileURL }) {
                let recipient = sharedInboxRecipients[inbox]
                writeDeliveryReceipts(messages, recipientPanelId: recipient?.id ?? panelId, via: "recv",
                                      recipient: { _ in recipient?.name ?? panelName })
            }
        }
    }

    /// Checked stdout write: false when the bytes could not be written.
    static func writeStdout(_ text: String) -> Bool {
        do {
            try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false
        }
    }

    // MARK: - recv --hook-format (turn-boundary drain)

    /// One prepared hook drain: the stdout JSON plus the envelopes it claimed.
    struct MailboxHookDrain {
        let json: String
        let claimed: [MailboxDrain.ClaimedMessage]
        let panelId: UUID
    }

    /// `c11 mailbox recv --drain --hook-format claude|codex|grok [--event
    /// stop]`, run by a harness's Stop hook at every turn end. The
    /// event comes from the hook's stdin JSON (`hook_event_name` /
    /// `hookEventName`); `--event` overrides it. Prints the harness's hook JSON
    /// only when it claimed mail. Every failure is silent with exit 0: this
    /// runs on every turn and must never block or error the harness.
    func runMailboxHookRecv(
        rawFormat: String,
        subArgs: [String],
        client: SocketClient,
        acknowledged: Bool
    ) {
        guard acknowledged else { return }
        guard let format = MailboxHookFormat(rawValue: rawFormat.lowercased()) else { return }
        let stdinData = isatty(STDIN_FILENO) == 0
            ? FileHandle.standardInput.readDataToEndOfFile()
            : Data()
        var input = MailboxHookInput.parse(stdinData)
        if let rawEvent = optionValue(subArgs, name: "--event") {
            input.event = MailboxHookEvent(name: rawEvent)
        }
        guard let drain = prepareMailboxHookDrain(
            format: format,
            input: input,
            acknowledged: true,
            scanWhenOwnerUnknown: true,
            client: client
        ) else {
            return
        }
        deliverMailboxHookDrain(drain, client: client)
    }

    /// Claims the caller's pending mail for a hook, within the context budget.
    /// Returns nil (and claims nothing) when this event may not drain, the
    /// inbox is empty, or the hook process is too old to finish in time.
    ///
    /// The inbox is the caller's C5 directory, `<mailboxes>/<C11_PANEL_ID>/`.
    /// An empty direct path falls back to a filesystem scan. On Claude Stop,
    /// if that direct path has mail, a bounded read-only panel lookup detects
    /// a stale workspace so retained inboxes across moves are found. A generic
    /// hook-format receive scans when its live owner is unknown.
    func prepareMailboxHookDrain(
        format: MailboxHookFormat,
        input: MailboxHookInput,
        acknowledged: Bool,
        resolveMovedPanelWorkspace: Bool = false,
        scanWhenOwnerUnknown: Bool = false,
        client: SocketClient
    ) -> MailboxHookDrain? {
        let env = ProcessInfo.processInfo.environment
        guard env["C11_MAILBOX_HOOK_DRAIN"] != "0",
              MailboxHookOutput.shouldDrain(format: format, input: input),
              let panelId = Self.callerPanelEnv(env).flatMap(UUID.init(uuidString:)),
              let stateURL = try? MailboxLayout.defaultStateURL() else {
            return nil
        }
        let workspacesRoot = stateURL.appendingPathComponent(MailboxLayout.workspacesDirectoryName, isDirectory: true)
        let preferredWorkspaceId = (env["C11_WORKSPACE_ID"] ?? env["CMUX_WORKSPACE_ID"]).flatMap(UUID.init(uuidString:))
        let preferredHasPendingMail = preferredWorkspaceId.map { workspaceId in
            let preferredInbox = MailboxLayout.inboxURL(state: stateURL, workspaceId: workspaceId, panelId: panelId)
            return !MailboxDrain.pendingEntries(inbox: preferredInbox).isEmpty
        } ?? false
        let currentWorkspaceId = preferredHasPendingMail && resolveMovedPanelWorkspace
            ? liveWorkspaceIdForMailboxPanel(panelId, client: client)
            : nil
        let inboxes = MailboxDrain.panelInboxURLs(
            workspacesRoot: workspacesRoot,
            preferredWorkspaceId: preferredWorkspaceId,
            currentWorkspaceId: currentWorkspaceId,
            scanWhenOwnerUnknown: scanWhenOwnerUnknown,
            panelId: panelId,
            scanCache: stateURL
                .appendingPathComponent("mailbox-tab-scan", isDirectory: true)
                .appendingPathComponent(panelId.uuidString.lowercased())
        )
        guard !inboxes.isEmpty,
              MailboxHookOutput.mayClaim(processElapsedSeconds: Self.processElapsedSeconds()) else {
            return nil
        }
        // `acknowledged` is the caller's statement that something will read
        // this stdout (the harness, for `claude-hook stop`; `--ack` or a
        // terminal, for `mailbox recv --hook-format`). Without it the claim
        // does not run.
        let claimed: [MailboxDrain.ClaimedMessage]
        let remaining: Int
        do {
            (claimed, remaining) = try MailboxRecvAdmission.consume(
                inboxes: inboxes,
                stdoutIsTTY: false,
                acknowledged: acknowledged,
                budget: MailboxHookOutput.contextBudget
            )
        } catch is MailboxRecvAdmission.Refusal {
            return nil
        } catch {
            // `consume` only throws Refusal, and it throws before any claim.
            // A hook still must not fail the harness if that changes.
            return nil
        }
        guard !claimed.isEmpty else { return nil }
        let context = MailboxHookOutput.context(framedBlocks: claimed.map(\.framed), remaining: remaining)
        let json = MailboxHookOutput.render(MailboxHookOutput.payload(context: context, format: format))
        guard !json.isEmpty else {
            claimed.forEach { MailboxDrain.unclaim($0.readURL) }
            return nil
        }
        return MailboxHookDrain(json: json, claimed: claimed, panelId: panelId)
    }

    /// Resolves the owning workspace of one explicit panel without consulting
    /// the selected workspace. Stop-hook mail is already claimable from the
    /// preferred path, so this bounded read only detects a move when that old
    /// inbox also contains mail.
    func liveWorkspaceIdForMailboxPanel(_ panelId: UUID, client: SocketClient) -> UUID? {
        guard let payload = try? client.sendV2(
            method: "panel.list",
            params: ["surface_id": panelId.uuidString],
            deadline: .custom(Self.claudeHookSocketWindowSeconds)
        ), let rawWorkspaceId = payload["workspace_id"] as? String else {
            return nil
        }
        return UUID(uuidString: rawWorkspaceId)
    }

    /// The invocations that may claim mailbox mail inside a harness hook:
    /// `claude-hook stop|prompt-submit` and `mailbox recv --hook-format`.
    static func isMailboxHookDrain(command: String, commandArgs: [String]) -> Bool {
        switch command {
        case "claude-hook":
            let sub = commandArgs.first?.lowercased()
            return sub == "stop" || sub == "prompt-submit"
        case "mailbox":
            return commandArgs.first == "recv" && commandArgs.contains("--hook-format")
        default:
            return false
        }
    }

    /// One Claude hook socket window: the time its socket requests share
    /// before the hook gives up on c11 and exits neutral.
    static let claudeHookSocketWindowSeconds: TimeInterval = 0.250

    /// Caps every socket request this hook process makes at the claim
    /// cutoff (`MailboxHookOutput.claimDeadlineSeconds` of process age), write
    /// and read alike. Requests after the cutoff fail at once, and the cutoff
    /// itself means no claim happens past it, so the hook finishes well before
    /// the harness's 10 s kill however c11 behaves.
    static func boundSocketToClaimCutoff() {
        let age = processElapsedSeconds() ?? 0
        SocketClient.processDeadline = Date(timeIntervalSinceNow: MailboxHookOutput.claimDeadlineSeconds - age)
    }

    /// Seconds since this process started, from the kernel's record of its
    /// start time (so it includes everything before `main`); nil if unknown.
    static func processElapsedSeconds() -> TimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - started
    }

    /// Writes the hook JSON to stdout. If the write fails the claimed envelopes
    /// go back to the inbox (C3-order), otherwise each one is recorded as
    /// `mailbox.delivered` with `via: "drain"`, under the workspace whose inbox
    /// held it, through a receipt the app picks up. Returns whether it
    /// delivered (the write, not the receipt).
    @discardableResult
    func deliverMailboxHookDrain(_ drain: MailboxHookDrain, client: SocketClient) -> Bool {
        signal(SIGPIPE, SIG_IGN)
        guard Self.writeStdout(drain.json + "\n") else {
            drain.claimed.forEach { MailboxDrain.unclaim($0.readURL) }
            return false
        }
        // No socket I/O after the claim: the delivery is recorded through the
        // filesystem, and the hook is done.
        writeDeliveryReceipts(drain.claimed, recipientPanelId: drain.panelId, via: "hook") {
            $0.recipient ?? drain.panelId.uuidString.lowercased()
        }
        return true
    }

    /// Hands claimed envelopes to the app as `mailbox.delivered via:"drain"`:
    /// receipts per workspace whose inbox they came from (split to fit the
    /// receipt limits), written atomically into that workspace's `_receipts/`
    /// spool. Filesystem only, so nothing a
    /// stalled, paused or quit c11 does can delay the caller, and no
    /// connection has to be authorized. `recipientTabId` nil leaves the
    /// event without a surface rather than attributing it to the caller.
    func writeDeliveryReceipts(
        _ claimed: [MailboxDrain.ClaimedMessage],
        recipientPanelId: UUID?,
        via: String,
        recipient: (MailboxDrain.ClaimedMessage) -> String
    ) {
        let byMailboxesRoot = Dictionary(grouping: claimed) { $0.inbox.deletingLastPathComponent().path }
        // C11-550: who claimed it, so a receipt can tell the recipient's own
        // read from another panel draining its inbox.
        let claimer = MailboxClaimLog.callerPanelId()
        for (root, messages) in byMailboxesRoot {
            let mailboxesRoot = URL(fileURLWithPath: root, isDirectory: true)
            MailboxDeliveryReceipt(
                panelId: recipientPanelId,
                deliveries: messages.map { .init(id: $0.id, recipient: recipient($0)) }
            ).writeAll(mailboxesRoot: mailboxesRoot)
            // The inbox directory names its panel; a legacy title inbox does not.
            for (inbox, group) in Dictionary(grouping: messages, by: { $0.inbox.lastPathComponent }) {
                MailboxClaimLog.append(
                    ids: group.map(\.id),
                    recipientPanel: UUID(uuidString: inbox) ?? recipientPanelId,
                    byPanel: claimer,
                    via: via,
                    mailboxesRoot: mailboxesRoot
                )
            }
        }
    }

    // MARK: - status (C11-550)

    /// `c11 mailbox status <id> [--json]`: sent, delivered and read per
    /// recipient, from the dispatch log and the recipient's inbox files. File
    /// first like `trace`: no socket, so it works with c11 down.
    func runMailboxStatusCommand(subArgs: [String], jsonOutput: Bool) throws {
        let words = subArgs.filter { !$0.hasPrefix("--") }
        guard words.count == 1, let id = words.first else {
            throw CLIError(message: String(
                localized: "mailbox.status.usage",
                defaultValue: "c11 mailbox status <envelope-id> [--json]"
            ))
        }
        let stateURL = try MailboxLayout.defaultStateURL()
        let workspacesRoot = stateURL.appendingPathComponent(MailboxLayout.workspacesDirectoryName, isDirectory: true)
        let report: MailboxReceiptStatus.Report
        do {
            report = try MailboxReceiptStatus.status(id: id, workspacesRoot: workspacesRoot)
        } catch MailboxReceiptStatus.Failure.invalidId(let raw) {
            throw CLIError(message: String(
                localized: "mailbox.status.error.invalidId",
                defaultValue: "'\(raw)' is not an envelope id (a 26-character ULID)"
            ))
        } catch MailboxReceiptStatus.Failure.scanLimit(let missing) {
            throw CLIError(message: String(
                localized: "mailbox.status.error.scanLimit",
                defaultValue: "the scan limit was reached before envelope \(missing) was found; it may still exist"
            ))
        } catch MailboxReceiptStatus.Failure.notFound(let missing) {
            throw CLIError(message: String(
                localized: "mailbox.status.error.notFound",
                defaultValue: "no envelope \(missing) in any workspace's dispatch log or outbox"
            ))
        }
        if jsonOutput {
            let data = try JSONSerialization.data(withJSONObject: report.jsonObject(), options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(report.humanText(), terminator: "")
        }
    }

    // MARK: - trace

    func runMailboxTraceCommand(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let id = subArgs.first(where: { !$0.hasPrefix("--") }) else {
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.trace.usage",
                    defaultValue: "c11 mailbox trace <envelope-id>"
                )
            )
        }
        // Trace globally: a cross-workspace send is dispatched in the
        // *recipient's* workspace, so its delivery/rejection events land in
        // that workspace's `_dispatch.log`, not the sender's. Scanning every
        // workspace's log (the envelope id is an instance-unique ULID) makes a
        // message followable wherever it routed. No socket call — trace works
        // even when the socket is unreachable, which is exactly when you need
        // to diagnose a stuck send.
        let stateURL = try MailboxLayout.defaultStateURL()
        let workspacesRoot = stateURL.appendingPathComponent(
            MailboxLayout.workspacesDirectoryName,
            isDirectory: true
        )
        let needle = "\"\(id)\""
        var matches: [(ts: String, line: String)] = []
        let workspaceDirs = (try? FileManager.default.contentsOfDirectory(
            at: workspacesRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        for workspaceDir in workspaceDirs {
            guard let workspaceId = UUID(uuidString: workspaceDir.lastPathComponent) else {
                continue
            }
            let logURL = MailboxLayout.dispatchLogURL(state: stateURL, workspaceId: workspaceId)
            guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true)
            where line.contains(needle) {
                let lineStr = String(line)
                let ts = (try? JSONSerialization.jsonObject(with: Data(lineStr.utf8)))
                    .flatMap { ($0 as? [String: Any])?["ts"] as? String } ?? ""
                matches.append((ts, lineStr))
            }
        }
        // ISO-8601 UTC timestamps sort lexically into chronological order, so a
        // string sort merges events from multiple workspace logs correctly.
        matches.sort { $0.ts < $1.ts }
        let text = MailboxHoldNotice.traceText(
            lines: matches.map(\.line),
            jsonOutput: jsonOutput
        )
        if !text.isEmpty {
            print(text, terminator: "")
        }
    }

    // MARK: - tail

    func runMailboxTailCommand(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let (workspaceId, _, _, _) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: nil
        )
        let stateURL = try MailboxLayout.defaultStateURL()
        let logURL = MailboxLayout.dispatchLogURL(state: stateURL, workspaceId: workspaceId)

        // Print existing contents, then poll for growth. A hold's plain
        // sentence is added here; the log file stays JSON. `pending` keeps a
        // line that arrived split across two reads.
        var lastSize: UInt64 = 0
        var pending = ""
        func flushHandle(_ handle: FileHandle) {
            let data = (try? handle.readToEnd()) ?? nil ?? Data()
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                let annotated = MailboxHoldNotice.annotateChunk(
                    text,
                    pending: pending,
                    jsonOutput: jsonOutput
                )
                pending = annotated.pending
                if !annotated.shown.isEmpty {
                    print(annotated.shown, terminator: "")
                    fflush(stdout)
                }
            }
            lastSize = (try? handle.offset()) ?? lastSize
        }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forReadingFrom: logURL) {
            flushHandle(handle)
            try? handle.close()
        }
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            guard FileManager.default.fileExists(atPath: logURL.path) else { continue }
            guard let handle = try? FileHandle(forReadingFrom: logURL) else { continue }
            try? handle.seek(toOffset: lastSize)
            flushHandle(handle)
            try? handle.close()
        }
    }

    // MARK: - Events stream (C11-163)

    /// `c11 events <subcommand>`. File-first: reads the per-instance NDJSON
    /// event log directly, no socket. Currently only `tail`.
    func runEventsCommand(commandArgs: [String], jsonOutput: Bool) throws {
        let sub = commandArgs.first?.lowercased() ?? "help"
        switch sub {
        case "tail":
            try runEventsTail(subArgs: Array(commandArgs.dropFirst()))
        case "help", "--help", "-h":
            print(eventsUsage())
        default:
            print(eventsUsage())
            throw CLIError(message: "events: unknown subcommand '\(sub)'. Known: tail")
        }
    }

    func eventsUsage() -> String {
        """
        Usage: c11 events tail [--follow|-f] [--filter type=<type>|supervisor] [--since <seq|duration>] [--instance <id>]

        Stream the c11 events log (NDJSON). The file is the contract — this is
        sugar over `~/Library/Application Support/c11/events/events-<instance>.ndjson`.
        Works with no running app.

          --follow, -f          Keep streaming new events (rotation-aware).
          --filter <value>     Exact type=<type>, or supervisor for lifecycle,
                                permission, interruption and stall events.
          --since <seq|dur>     Start at a seq number (e.g. 1200) or a duration
                                ago (e.g. 10m, 90s, 2h), resolved against `ts`.
          --instance <id>       Target a specific instance log (default: newest).

        Examples:
          c11 events tail
          c11 events tail -f --filter type=panel.closed
          c11 events tail -f --filter supervisor
          c11 events tail --since 5m
        """
    }

    /// Reads the current instance log, applies filters, prints matching lines.
    /// One-shot by default; `--follow` streams with rotation detection so the
    /// tail survives a size-capped roll (amendment A) — the mailbox loop cannot,
    /// because the mailbox log never rotates.
    func runEventsTail(subArgs: [String]) throws {
        let follow = hasFlag(subArgs, name: "--follow") || hasFlag(subArgs, name: "-f")
        // C11-337: compare canonical types so a v1 spelling (`surface.created`,
        // `tab.input_sent`) and its v2 name (`panel.*`) match either line form.
        let typeFilter = eventsTypeFilter(subArgs)
        let sinceSeq = eventsSinceSeq(subArgs)
        let sinceDate = eventsSinceDate(subArgs)
        let instance = optionValue(subArgs, name: "--instance")

        let state = try EventLogLayout.defaultStateURL()
        let logURL: URL
        if let instance {
            logURL = EventLogLayout.logURL(state: state, instance: instance)
        } else {
            do {
                logURL = try EventLogLayout.newestLogURL(state: state)
            } catch {
                // No log yet. In --follow, wait for one to appear; else exit 0.
                if !follow { return }
                logURL = try eventsWaitForLog(state: state)
            }
        }

        // Emit a line iff it passes every active filter.
        func emit(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !EventEnvelope.matchesFilter(typeFilter, type: EventEnvelope.canonicalType(fromLine: trimmed)) { return }
            if let sinceSeq, let s = EventEnvelope.seq(fromLine: trimmed), s < sinceSeq { return }
            if let sinceDate, let ts = EventEnvelope.timestamp(fromLine: trimmed), ts < sinceDate { return }
            print(trimmed)
        }

        func drainLines(_ text: String) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                emit(String(line))
            }
            fflush(stdout)
        }

        // Initial read of the whole current file.
        var lastSize: UInt64 = 0
        var lastInode = eventsInode(of: logURL)
        if let handle = try? FileHandle(forReadingFrom: logURL) {
            let data = (try? handle.readToEnd()) ?? nil ?? Data()
            if let text = String(data: data, encoding: .utf8) { drainLines(text) }
            lastSize = (try? handle.offset()) ?? 0
            try? handle.close()
        } else if let instance, !follow {
            // C11-348: retention removes old instance logs. Say so rather than
            // exit silently, so a caller can tell "no events" from "no log".
            let note = FileManager.default.fileExists(atPath: logURL.path)
                ? "note: cannot read the event log for instance \(instance) at \(logURL.path)\n"
                : "note: no event log for instance \(instance); it was never written or retention removed it\n"
            FileHandle.standardError.c11SafeWrite(Data(note.utf8))
        }

        guard follow else { return }

        // C11-385: this loop never returns, so its thread's root pool never
        // drains. One pool per poll releases the FileManager/FileHandle/String
        // temporaries each iteration instead of holding them for the process.
        func pollOnce() {
            guard FileManager.default.fileExists(atPath: logURL.path) else { return }
            let currentInode = eventsInode(of: logURL)
            // A follow that started before the log existed learns its inode
            // here, so a later roll can be matched against `.1`.
            if lastInode == 0, currentInode != 0, lastSize == 0 { lastInode = currentInode }
            let currentSize = eventsFileSize(of: logURL)
            // Rotation detection: the file shrank, or its inode changed → the log
            // rolled. A `0` inode means a transient stat failure (e.g. mid-rename);
            // treat it as "unknown" and do not reset on it alone.
            let inodeChanged = currentInode != 0 && lastInode != 0 && currentInode != lastInode
            if inodeChanged || currentSize < lastSize {
                // Before switching to the fresh file, drain the tail that landed
                // in the now-rolled `.1` after our last read — the cap-crossing
                // lines the writer appended just before it renamed. Without this
                // the sub-second unread tail would live only in `.1` and the
                // follower would skip it.
                let rolled = EventLogLayout.rolledURL(for: logURL)
                // C11-348: only when `.1` is the file we were reading. After a
                // recovery (`rolled_to: null`) the live file was deleted, and
                // `.1` is an older, unrelated generation.
                if lastInode != 0, eventsInode(of: rolled) == lastInode,
                   let rh = try? FileHandle(forReadingFrom: rolled) {
                    try? rh.seek(toOffset: lastSize)
                    let tail = ((try? rh.readToEnd()) ?? nil) ?? Data()
                    if let text = String(data: tail, encoding: .utf8), !text.isEmpty { drainLines(text) }
                    try? rh.close()
                }
                lastSize = 0
                if currentInode != 0 { lastInode = currentInode }
            }
            guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
            try? handle.seek(toOffset: lastSize)
            let data = ((try? handle.readToEnd()) ?? nil) ?? Data()
            if let text = String(data: data, encoding: .utf8), !text.isEmpty { drainLines(text) }
            lastSize = (try? handle.offset()) ?? lastSize
            try? handle.close()
        }

        while true {
            Thread.sleep(forTimeInterval: 0.25)
            autoreleasepool { pollOnce() }
        }
    }

    /// Blocks (polling) until an instance log exists, for `--follow` started
    /// before the app opened its log.
    func eventsWaitForLog(state: URL) throws -> URL {
        while true {
            if let url = autoreleasepool(invoking: { try? EventLogLayout.newestLogURL(state: state) }) { return url }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    func eventsTypeFilter(_ args: [String]) -> String? {
        guard let raw = optionValue(args, name: "--filter") else { return nil }
        // Accept `--filter type=surface.closed` (or a bare `type=` value).
        if raw.hasPrefix("type=") { return String(raw.dropFirst("type=".count)) }
        return raw
    }

    func eventsSinceSeq(_ args: [String]) -> UInt64? {
        guard let raw = optionValue(args, name: "--since") else { return nil }
        return UInt64(raw)
    }

    /// Parses `--since <duration>` (e.g. 10m, 90s, 2h, 1d) into an absolute
    /// cutoff date. Returns nil when `--since` is absent or a plain seq number.
    func eventsSinceDate(_ args: [String]) -> Date? {
        guard let raw = optionValue(args, name: "--since"), UInt64(raw) == nil else { return nil }
        guard let unit = raw.last, let value = Double(raw.dropLast()) else { return nil }
        let seconds: Double
        switch unit {
        case "s": seconds = value
        case "m": seconds = value * 60
        case "h": seconds = value * 3600
        case "d": seconds = value * 86400
        default: return nil
        }
        return Date().addingTimeInterval(-seconds)
    }

    func eventsInode(of url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.systemFileNumber] as? UInt64) ?? 0
    }

    func eventsFileSize(of url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? UInt64) ?? 0
    }

    // MARK: - Helpers for raw-bash senders/receivers

    func runMailboxOutboxDirCommand(
        subArgs: [String],
        client: SocketClient
    ) throws {
        let (workspaceId, _, _, _) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: nil
        )
        let stateURL = try MailboxLayout.defaultStateURL()
        let url = MailboxLayout.outboxURL(state: stateURL, workspaceId: workspaceId)
        print(url.path)
    }

    func runMailboxInboxDirCommand(
        subArgs: [String],
        client: SocketClient
    ) throws {
        let surfaceOverride = optionValue(subArgs, name: "--panel")
        let (workspaceId, panelName, callerPanelId, _) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: surfaceOverride
        )
        guard let panelId = resolveMailboxInboxPanelId(
            client: client,
            workspaceId: workspaceId,
            panelName: panelName,
            panelId: callerPanelId
        ) else {
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.error.surface-not-found",
                    defaultValue: "No panel named %@ in this workspace."
                ).replacingOccurrences(of: "%@", with: panelName)
            )
        }
        let stateURL = try MailboxLayout.defaultStateURL()
        let resolution = try? client.sendV2(method: "mailbox.resolve", params: [
            "to": "id:\(panelId.uuidString)", "sender_workspace_id": workspaceId.uuidString
        ])
        let owner = (resolution?["recipients"] as? [[String: Any]])?.first
        let actualPanel = (owner?["panel_id"] as? String).flatMap(UUID.init(uuidString:)) ?? panelId
        let actualWorkspace = (owner?["workspace_id"] as? String).flatMap(UUID.init(uuidString:)) ?? workspaceId
        let url = MailboxLayout.inboxURL(state: stateURL, workspaceId: actualWorkspace, panelId: actualPanel)
        print(url.path)
    }

    func runMailboxSurfaceNameCommand(
        subArgs: [String],
        client: SocketClient
    ) throws {
        let (_, panelName, _, _) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: nil
        )
        print(panelName)
    }

    func runMailboxSenderFromCommand(
        subArgs: [String],
        client: SocketClient
    ) throws {
        let (_, panelName, panelId, mailboxAddress) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: nil
        )
        guard let from = MailboxSenderFrom.defaultValue(
            title: panelName,
            mailboxAddress: mailboxAddress,
            panelId: panelId
        ) else {
            throw CLIError(message: "C11_PANEL_ID not set — pass --from <panel> to override")
        }
        print(from)
    }
}
