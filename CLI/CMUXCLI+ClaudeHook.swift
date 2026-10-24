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

extension CMUXCLI {

    /// Bundle-private lifecycle bridge used by agent wrappers and runtime
    /// plugins. Interactive agent processes keep the outer shell in `running`
    /// for their entire lifetime, so providers report their truthful loop
    /// state through this command. `codex-hook` remains as a compatibility
    /// alias for already-installed c11 builds and wrapper fixtures.
    func runAgentHook(
        commandName: String,
        commandArgs: [String],
        client: SocketClient
    ) throws {
        guard let rawActivity = commandArgs.first?.lowercased(),
              rawActivity == "working" || rawActivity == "idle" else {
            throw CLIError(message: "\(commandName) requires working or idle")
        }
        let environment = ProcessInfo.processInfo.environment
        guard let workspaceId = environment["CMUX_WORKSPACE_ID"] ?? environment["C11_WORKSPACE_ID"],
              UUID(uuidString: workspaceId) != nil else {
            throw CLIError(message: "\(commandName) requires a c11 workspace id")
        }
        guard let surfaceId = Self.callerPanelEnv(environment),
              UUID(uuidString: surfaceId) != nil else {
            throw CLIError(message: "\(commandName) requires a c11 panel id")
        }
        if let native = optionValue(commandArgs, name: "--native-event"), ["agent_start", "agent_settled"].contains(native) {
            let ref = try? client.sendV2(method: "conversation.get", params: ["panel_id": surfaceId])
            let active = (ref?["active"] as? [String: Any]) ?? ((ref?["conversation"] as? [String: Any])?["active"] as? [String: Any])
            let claimedID = (active?["kind"] as? String) == "pi" ? active?["id"] as? String : nil
            // A wrapper placeholder is not a confirmed journal owner. Keep
            // reporting the live PID's turn edges until Pi has a real session.
            let sessionID = claimedID.flatMap { $0.hasPrefix("wrapper-claim:") ? nil : $0 }
            let draft = JournalDraft(kind: native == "agent_start" ? .turnStarted : .turnCompleted,
                emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000), panelID: UUID(uuidString: surfaceId),
                workspaceID: UUID(uuidString: workspaceId), sessionID: sessionID, agentKind: "pi",
                source: .plugin, adapter: .piPlugin, nativeEvent: native)
            let delivery = JournalCommand.deliver(draft, socketPath: client.socketPath, authenticatedClient: client)
            if case .unsupported = delivery { /* Explicit older-app compatibility. */ }
            else if sessionID != nil { print("OK"); return }
        }
        let response = try sendV1Command(
            "report_agent_activity \(rawActivity) --tab=\(workspaceId) --panel=\(surfaceId)\(Self.agentLifecycleReportOptions())",
            client: client
        )
        print(response)
    }

    func runClaudeHook(
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        rawInput: String,
        journalDraft: JournalDraft?,
        socketCeiling: Date?
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let hookArgs = Array(commandArgs.dropFirst())
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let workspaceArg = hookWsFlag ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let surfaceArg = optionValue(hookArgs, name: "--panel") ?? (hookWsFlag == nil ? Self.callerPanelEnv() : nil)
        // C11-24 diagnostic: when CMUX_HOOK_DEBUG_PATH is set, dump the
        // raw stdin JSON to that path before parsing. Used to verify the
        // exact shape of the SessionStart payload Claude Code emits when
        // session_id capture appears to be silently dropping. Best-effort —
        // any I/O error is swallowed so a misconfigured debug path can
        // never break the hook itself.
        if let debugPath = ProcessInfo.processInfo.environment["CMUX_HOOK_DEBUG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !debugPath.isEmpty {
            try? rawInput.write(toFile: debugPath, atomically: true, encoding: .utf8)
        }
        let parsedInput = parseClaudeHookInput(rawInput: rawInput)
        let sessionStore = ClaudeHookSessionStore()
        func nonBlockingSession(_ sessionID: String?) -> ClaudeHookSessionRecord? {
            guard let sessionID else { return nil }
            if case .found(let record) = sessionStore.lookupNonBlocking(sessionId: sessionID) {
                return record
            }
            return nil
        }
        telemetry.breadcrumb(
            "claude-hook.input",
            data: [
                "subcommand": subcommand,
                "has_session_id": parsedInput.sessionId != nil,
                "has_workspace_flag": hookWsFlag != nil,
                "has_surface_flag": optionValue(hookArgs, name: "--panel") != nil
            ]
        )
        func spoolJournalDraft() {
            if let journalDraft { _ = JournalCommand.spool(journalDraft) }
        }

        // Claim Stop-hook mail before advisory lifecycle workspace resolution.
        // The inbox miss path stays filesystem-only; a pending preferred inbox
        // may use a bounded panel lookup to include a moved panel's live path.
        if subcommand == "stop",
           let drain = prepareMailboxHookDrain(
               format: .claude,
               input: claudeMailboxHookInput(event: .stop, parsedInput: parsedInput),
               acknowledged: true,
               resolveMovedPanelWorkspace: true,
               client: client
           ),
           deliverMailboxHookDrain(drain, client: client) {
            telemetry.breadcrumb("claude-hook.stop.mailbox-delivered")
            return
        }

        let fallbackWorkspaceId: String
        do {
            fallbackWorkspaceId = try resolveWorkspaceIdForClaudeHook(workspaceArg, client: client)
        } catch {
            // Owner discovery is advisory. Preserve the pre-created structural
            // draft and keep the hook's output neutral when the peer is silent.
            spoolJournalDraft()
            if subcommand == "permission-request" { print("{}") }
            return
        }
        var journalDelivery: JournalCommand.Delivery?
        func managedJournalDelivery(_ delivery: JournalCommand.Delivery) -> Bool {
            switch delivery {
            // Only a confirmed absent method permits the body-bearing legacy route.
            // Failed delivery to a journal-capable app must remain structural.
            case .committed, .spooled, .lost, .rejected: return true
            case .unsupported: return false
            }
        }
        func appendJournal(workspaceId: String, surfaceId: String) -> Bool {
            if let journalDelivery { return managedJournalDelivery(journalDelivery) }
            guard var draft = journalDraft else { return true }
            draft.panelID = UUID(uuidString: surfaceId)
            draft.workspaceID = UUID(uuidString: workspaceId)
            let delivery = JournalCommand.deliver(draft, socketPath: client.socketPath, authenticatedClient: client)
            journalDelivery = delivery
            return managedJournalDelivery(delivery)
        }
        func appendResolvedJournal() {
            var workspaceId = fallbackWorkspaceId
            var preferredSurface = surfaceArg
            if let sessionId = parsedInput.sessionId {
                switch sessionStore.lookupNonBlocking(sessionId: sessionId) {
                case .found(let mapped):
                    do {
                        workspaceId = try resolveWorkspaceIdForClaudeHook(mapped.workspaceId, client: client)
                        preferredSurface = mapped.surfaceId
                    } catch {
                        spoolJournalDraft()
                        return
                    }
                case .missing:
                    break
                case .unavailable:
                    // Do not take LOCK_EX on a hook observer's deadline path.
                    // The draft was constructed before connect and remains
                    // recoverable in the existing spool.
                    spoolJournalDraft()
                    return
                }
            }
            do {
                let resolvedSurface = try resolveSurfaceIdForClaudeHook(
                    preferredSurface,
                    workspaceId: workspaceId,
                    client: client
                )
                _ = appendJournal(workspaceId: workspaceId, surfaceId: resolvedSurface)
            } catch {
                spoolJournalDraft()
            }
        }
        func reportAgentActivity(client: SocketClient, workspaceId: String, surfaceId: String,
                                 activity: String, fromNotification: Bool = false) throws {
            if !appendJournal(workspaceId: workspaceId, surfaceId: surfaceId) {
                try self.reportAgentActivity(client: client, workspaceId: workspaceId, surfaceId: surfaceId,
                                             activity: activity, fromNotification: fromNotification)
            }
        }


        switch subcommand {
        case "session-start", "active":
            telemetry.breadcrumb("claude-hook.session-start")
            let workspaceId = fallbackWorkspaceId
            let surfaceId = try resolveSurfaceIdForClaudeHook(
                surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            let claudePid: Int? = {
                guard let raw = ProcessInfo.processInfo.environment["CMUX_CLAUDE_PID"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    let pid = Int(raw),
                    pid > 0 else {
                    return nil
                }
                return pid
            }()
            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    pid: claudePid
                )
                // C11-24 conversation store: route the SessionStart id
                // into ConversationStore via conversation.push. Replaces
                // the older claude.session_id reserved-metadata write
                // (which raced SessionEnd on Cmd+Q). The legacy
                // claude.session_id reserved key is no longer written
                // here; the read-side bridge in WorkspaceSnapshotStore
                // continues to recognise it for one-release backcompat
                // (snapshots from 0.43.0/0.44.0-pre).
                let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedSessionId.isEmpty, !surfaceId.isEmpty {
                    var pushParams: [String: Any] = [
                        "panel_id": surfaceId,
                        "kind": "claude-code",
                        "id": trimmedSessionId,
                        "source": "hook",
                        "state": "alive"
                    ]
                    if let cwd = parsedInput.cwd, !cwd.isEmpty {
                        pushParams["cwd"] = cwd
                    }
                    do {
                        _ = try client.sendV2(method: "conversation.push", params: pushParams)
                        telemetry.breadcrumb("claude-hook.conversation.push.ok")
                    } catch let error as CLIError where isAdvisoryHookConnectivityError(error) {
                        telemetry.breadcrumb("claude-hook.conversation.push.skipped")
                    } catch {
                        telemetry.breadcrumb("claude-hook.conversation.push.failed")
                    }
                }
            }
            // A fresh, resumed or cleared session rests at its prompt. A
            // `compact` SessionStart fires mid-turn after auto-compaction, so
            // it must not claim the agent is idle.
            if (parsedInput.object?["source"] as? String) != "compact" {
                _ = try? reportAgentActivity(
                    client: client,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    activity: "idle"
                )
            }
            _ = appendJournal(workspaceId: workspaceId, surfaceId: surfaceId)
            // Register PID for stale-session detection and OSC suppression,
            // but don't set a visible status. "Running" only appears when the
            // user submits a prompt (UserPromptSubmit) or Claude starts working
            // (PreToolUse).
            if let claudePid {
                _ = try? sendV1Command(
                    "set_agent_pid claude_code \(claudePid) --tab=\(workspaceId) --panel=\(surfaceId)",
                    client: client
                )
            }
            // Inject a one-time orientation nudge into the fresh Claude
            // session. This SessionStart hook already fires for every claude
            // launched inside c11 — the Resources/bin/claude wrapper injects a
            // per-PID `--settings` tempfile that wires it — so emitting
            // hookSpecificOutput.additionalContext here reaches every in-c11
            // claude with no per-agent config write. Advisory only: the hook
            // must never fail startup, and jsonString() degrades to "{}" on any
            // malformed input, so the worst case is a session with no nudge.
            let orientation = "You are running inside a c11 panel: c11 is the terminal multiplexer hosting this session. Before other work, load the c11 skill. It owns panel naming, splits, panel targeting, sub-agent orchestration, the embedded browser, and sidebar telemetry. As your first action, name this panel so the operator can see your role: c11 rename-panel --panel \"$C11_PANEL_ID\" \"<2-4 word role>\". A working agent must not sit under \"Awaiting first task\"."
            let hookOutput: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "SessionStart",
                    "additionalContext": orientation
                ]
            ]
            print(jsonString(hookOutput))

        case "stop", "idle":
            telemetry.breadcrumb("claude-hook.stop")
            // C11-401: the drain is filesystem work whose inbox scan can stat
            // every workspace directory, and it ran inside the window armed
            // before connect. If the lifecycle report shared that window, a
            // slow scan would cost the turn's idle edge: the panel would read
            // as working and mail pushed to it would stay held. The report gets
            // a fresh window; the claim cutoff still caps the hook.
            SocketClient.processDeadline = min(
                socketCeiling ?? .distantFuture,
                Date().addingTimeInterval(Self.claudeHookSocketWindowSeconds)
            )
            // Turn ended. Don't consume session or clear PID — Claude is still alive.
            // Notification hook handles user-facing notifications; SessionEnd handles cleanup.
            var workspaceId = fallbackWorkspaceId
            var surfaceId = surfaceArg
            if let sessionId = parsedInput.sessionId,
               let mapped = nonBlockingSession(sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForClaudeHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
                surfaceId = mapped.surfaceId
            }
            let resolvedLifecycleSurface = try? resolveSurfaceIdForClaudeHook(
                surfaceId,
                workspaceId: workspaceId,
                client: client
            )


            if let resolvedLifecycleSurface {
                _ = try? reportAgentActivity(
                    client: client,
                    workspaceId: workspaceId,
                    surfaceId: resolvedLifecycleSurface,
                    activity: "idle"
                )
            }

            // Update session with transcript summary and send completion notification.
            let completion = summarizeClaudeHookStop(
                parsedInput: parsedInput,
                sessionRecord: nonBlockingSession(parsedInput.sessionId)
            )
            if let sessionId = parsedInput.sessionId, let completion {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId ?? "",
                    cwd: parsedInput.cwd,
                    lastSubtitle: completion.subtitle,
                    lastBody: completion.body
                )
            }

            if let completion {
                let resolvedSurface = try resolveSurfaceIdForClaudeHook(
                    surfaceId,
                    workspaceId: workspaceId,
                    client: client
                )
                let title = "Claude Code"
                let subtitle = sanitizeNotificationField(completion.subtitle)
                let body = sanitizeNotificationField(completion.body)
                let payload = "\(title)|\(subtitle)|\(body)"
                _ = try? sendV1Command("notify_target \(workspaceId) \(resolvedSurface) \(payload)", client: client)
            }

            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                surfaceId: resolvedLifecycleSurface,
                value: "Idle",
                icon: "pause.circle.fill",
                color: "#8E8E93"
            )
            print("OK")

        case "prompt-submit":
            telemetry.breadcrumb("claude-hook.prompt-submit")
            var workspaceId = fallbackWorkspaceId
            var preferredSurface = surfaceArg
            if let sessionId = parsedInput.sessionId,
               let mapped = nonBlockingSession(sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForClaudeHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
                preferredSurface = mapped.surfaceId
            }
            let resolvedSurface = try resolveSurfaceIdForClaudeHook(
                preferredSurface,
                workspaceId: workspaceId,
                client: client
            )
            _ = try? reportAgentActivity(
                    client: client,
                    workspaceId: workspaceId,
                    surfaceId: resolvedSurface,
                    activity: "working"
                )
            _ = try sendV1Command("clear_notifications --tab=\(workspaceId) --panel=\(resolvedSurface)", client: client)
            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                surfaceId: resolvedSurface,
                value: "Running",
                icon: "bolt.fill",
                color: "#4C8DFF"
            )
            // Prints nothing: Claude adds UserPromptSubmit stdout to the turn's
            // context. Mailbox mail is not drained here; it waits for this
            // turn's Stop, where Claude takes it as its own next turn.

        case "notification", "notify":
            telemetry.breadcrumb("claude-hook.notification")
            var summary = summarizeClaudeHookNotification(rawInput: rawInput)

            var workspaceId = fallbackWorkspaceId
            var preferredSurface = surfaceArg
            if let sessionId = parsedInput.sessionId,
               let mapped = nonBlockingSession(sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForClaudeHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
                preferredSurface = mapped.surfaceId
                // If PreToolUse saved a richer message (e.g. from AskUserQuestion),
                // use it instead of the generic notification text.
                if let savedBody = mapped.lastBody, !savedBody.isEmpty,
                   summary.body.contains("needs your attention") || summary.body.contains("needs your input") {
                    summary = (subtitle: mapped.lastSubtitle ?? summary.subtitle, body: savedBody)
                }
            }

            let surfaceId = try resolveSurfaceIdForClaudeHook(
                preferredSurface,
                workspaceId: workspaceId,
                client: client
            )
            _ = try? reportAgentActivity(
                client: client,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                activity: "idle",
                fromNotification: true
            )

            let title = "Claude Code"
            let subtitle = sanitizeNotificationField(summary.subtitle)
            let body = sanitizeNotificationField(summary.body)
            let payload = "\(title)|\(subtitle)|\(body)"

            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    lastSubtitle: summary.subtitle,
                    lastBody: summary.body
                )
            }

            let response = try client.send(command: "notify_target \(workspaceId) \(surfaceId) \(payload)")
            _ = try? setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            )
            print(response)

        case "session-end":
            telemetry.breadcrumb("claude-hook.session-end")
            // Final cleanup when Claude process exits.
            // Only clear when we are the primary cleanup path (Stop didn't fire first).
            // If Stop already consumed the session, consumedSession is nil and we skip
            // to avoid wiping the completion notification that Stop just delivered.
            let mappedSession = nonBlockingSession(parsedInput.sessionId)
            let cleanupWorkspace = mappedSession?.workspaceId ?? fallbackWorkspaceId
            guard let cleanupSurface = try? resolveSurfaceIdForClaudeHook(
                mappedSession?.surfaceId ?? surfaceArg,
                workspaceId: cleanupWorkspace,
                client: client
            ) else {
                print("OK")
                return
            }
            _ = appendJournal(workspaceId: cleanupWorkspace, surfaceId: cleanupSurface)
            let consumedSession = try? sessionStore.consume(
                sessionId: parsedInput.sessionId,
                workspaceId: cleanupWorkspace,
                surfaceId: cleanupSurface
            )
            if let consumedSession {
                let workspaceId = consumedSession.workspaceId
                _ = try? clearClaudeStatus(client: client, workspaceId: workspaceId)
                _ = try? sendV1Command("clear_agent_pid claude_code --tab=\(workspaceId)", client: client)
                _ = try? sendV1Command("clear_notifications --tab=\(workspaceId) --panel=\(consumedSession.surfaceId)", client: client)
                // C11-24: SessionEnd race fix.
                //
                // The legacy code path here cleared `claude.session_id`
                // from surface metadata — but on Cmd+Q, c11 kills
                // terminals → claude exits → SessionEnd fires →
                // metadata cleared, racing the snapshot capture. By
                // next launch, per-surface session ids were gone (one
                // of the bugs this primitive was built to fix).
                //
                // New semantics: query is_terminating_app via
                // system.ping (250 ms bounded). If the app is
                // terminating, NO-OP (preserve the ref so resume on
                // next launch still works). If not, push state="ended"
                // → store maps to .unknown so next-launch scrape
                // reclassifies (the hook can't distinguish user
                // /exit from Claude crash, terminal kill, or wrapper
                // failure; tombstoning unconditionally would refuse
                // auto-resume of work the user expected to continue).
                //
                // CLI policy on socket failure: treat unreachable /
                // timeout as terminating, so we err on preservation,
                // never tombstone on socket-uncertainty.
                let surfaceId = consumedSession.surfaceId
                let isTerminating = isAppCurrentlyTerminating(client: client, telemetry: telemetry)
                if isTerminating {
                    telemetry.breadcrumb("claude-hook.session-end.skipped-during-shutdown")
                } else if let sessionId = parsedInput.sessionId, !surfaceId.isEmpty {
                    let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        var params: [String: Any] = [
                            "panel_id": surfaceId,
                            "kind": "claude-code",
                            "id": trimmed,
                            "source": "hook",
                            "state": "ended",
                            // C11-24 review (B3): server-side handler reads
                            // `diagnostic_reason`. Sending bare `reason` here
                            // dropped the SessionEnd context silently.
                            "diagnostic_reason": "SessionEnd (TUI exited; reclassify on next launch)"
                        ]
                        if !workspaceId.isEmpty {
                            params["workspace_id"] = workspaceId
                        }
                        do {
                            _ = try client.sendV2(method: "conversation.push", params: params)
                            telemetry.breadcrumb("claude-hook.session-end.ended.ok")
                        } catch let error as CLIError where isAdvisoryHookConnectivityError(error) {
                            telemetry.breadcrumb("claude-hook.session-end.ended.skipped")
                        } catch {
                            telemetry.breadcrumb("claude-hook.session-end.ended.failed")
                        }
                    }
                }
            }
            print("OK")

        case "pre-tool-use", "post-tool-use":
            telemetry.breadcrumb("claude-hook.\(subcommand)")
            // Clears "Needs input" status and notification when Claude resumes work
            // (e.g. after permission grant). Runs async so it doesn't block tool execution.
            var workspaceId = fallbackWorkspaceId
            var claudePid: Int? = nil
            var preferredSurface = surfaceArg
            if let sessionId = parsedInput.sessionId,
               let mapped = nonBlockingSession(sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForClaudeHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
                claudePid = mapped.pid
                preferredSurface = mapped.surfaceId
            }

            let resolvedSurface = try resolveSurfaceIdForClaudeHook(
                preferredSurface, workspaceId: workspaceId, client: client
            )
            let toolName = parsedInput.object?["tool_name"] as? String
            if subcommand == "post-tool-use", toolName != "AskUserQuestion", toolName != "ExitPlanMode" {
                _ = appendJournal(workspaceId: workspaceId, surfaceId: resolvedSurface)
                print("OK")
                return
            }
            let permissionMode = parsedInput.object?["permission_mode"] as? String
            let bypass = permissionMode == "bypassPermissions"
            // A bypass-started session emits ExitPlanMode in plan mode while
            // its approval UI waits. The native trace has no Notification edge.
            let planApproval = toolName == "ExitPlanMode" && (bypass || permissionMode == "plan")
            if subcommand == "pre-tool-use" && (toolName == "AskUserQuestion" || planApproval) {
                // Append and the display note share one 250 ms budget. A missed note is not retried.
                let budgetEnd = Date().addingTimeInterval(0.250)
                let supported = appendJournal(workspaceId: workspaceId, surfaceId: resolvedSurface)
                let managed = supported && journalDraft != nil
                if !managed {
                    let subtitle = String(localized: "claudeHook.waiting", defaultValue: "Waiting")
                    let body: String
                    if toolName == "ExitPlanMode" {
                        body = String(localized: "claudeHook.planApproval", defaultValue: "Plan approval needed")
                    } else {
                        body = describeAskUserQuestion(parsedInput.object)
                            ?? String(localized: "claudeHook.waitingForInput", defaultValue: "Waiting for input")
                    }
                    if let sessionId = parsedInput.sessionId {
                        try? sessionStore.upsert(
                            sessionId: sessionId, workspaceId: workspaceId, surfaceId: resolvedSurface,
                            cwd: parsedInput.cwd, lastSubtitle: subtitle, lastBody: body
                        )
                    }
                    _ = try? reportAgentActivity(
                        client: client, workspaceId: workspaceId, surfaceId: resolvedSurface,
                        activity: "idle", fromNotification: true
                    )
                    if bypass || planApproval {
                        let payload = "Claude Code|\(sanitizeNotificationField(subtitle))|\(sanitizeNotificationField(body))"
                        _ = try sendV1Command("notify_target \(workspaceId) \(resolvedSurface) \(payload)", client: client)
                        try setClaudeStatus(
                            client: client, workspaceId: workspaceId, surfaceId: resolvedSurface,
                            value: "Needs input", icon: "bell.fill", color: "#4C8DFF", pid: claudePid
                        )
                    }
                } else {
                    if case .committed(let receipt) = journalDelivery, let eventID = receipt["event_id"] as? String {
                        let extracted = FeedDisplayExtract.claude(toolName: toolName, object: parsedInput.object)
                        if extracted.prompt != nil || extracted.options != nil {
                            let remaining = budgetEnd.timeIntervalSinceNow
                            if remaining > 0 {
                                FeedCommand.sendDisplayNote(
                                    client: client,
                                    workspaceID: workspaceId,
                                    panelID: resolvedSurface,
                                    sessionID: parsedInput.sessionId ?? journalDraft?.sessionID,
                                    eventID: eventID,
                                    requestID: journalDraft?.requestID,
                                    prompt: extracted.prompt,
                                    options: extracted.options,
                                    deadline: remaining
                                )
                            }
                        }
                    }
                    if bypass || planApproval {
                        try setClaudeStatus(
                            client: client,
                            workspaceId: workspaceId,
                            surfaceId: resolvedSurface,
                            value: "Needs input",
                            icon: "bell.fill",
                            color: "#4C8DFF",
                            pid: claudePid
                        )
                    }
                }
                print("OK")
                return
            }

            // Compatibility UI writes are advisory: even a stalled clear must
            // reach reportAgentActivity's structural append/spool below.
            _ = try? sendV1Command("clear_notifications --tab=\(workspaceId) --panel=\(resolvedSurface)", client: client)
            _ = try? reportAgentActivity(
                client: client, workspaceId: workspaceId, surfaceId: resolvedSurface, activity: "working"
            )

            let statusValue: String
            if UserDefaults.standard.bool(forKey: "claudeCodeVerboseStatus"),
               let toolStatus = describeToolUse(parsedInput.object) {
                statusValue = toolStatus
            } else {
                statusValue = "Running"
            }
            try? setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                surfaceId: resolvedSurface,
                value: statusValue,
                icon: "bolt.fill",
                color: "#4C8DFF",
                pid: claudePid
            )
            print("OK")

        case "stop-failure", "subagent-start", "subagent-stop", "pre-compact":
            telemetry.breadcrumb("claude-hook.\(subcommand)")
            appendResolvedJournal()
            print("OK")

        case "permission-request":
            telemetry.breadcrumb("claude-hook.permission-request")
            appendResolvedJournal()
            print("{}")

        case "help", "--help", "-h":
            telemetry.breadcrumb("claude-hook.help")
            print(
                """
                c11 claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use|post-tool-use|stop-failure|permission-request|subagent-start|subagent-stop|pre-compact> [--workspace <id|index>] [--panel <id|index>]
                """
            )

        default:
            throw CLIError(message: "Unknown claude-hook subcommand: \(subcommand)")
        }
    }

    func setClaudeStatus(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String? = nil,
        value: String,
        icon: String,
        color: String,
        pid: Int? = nil
    ) throws {
        var cmd = "set_status claude_code \(value) --icon=\(icon) --color=\(color) --tab=\(workspaceId)"
        if let surfaceId {
            cmd += " --panel=\(surfaceId)"
        }
        if let pid {
            cmd += " --pid=\(pid)"
        }
        _ = try client.send(command: cmd)
    }

    /// The agent-identity part of a lifecycle report. An interactive agent
    /// launch exports `C11_AGENT_INTERACTIVE_PID` from its c11 wrapper (its
    /// own PID, inherited by its hooks and plugins); the report carries it so
    /// c11 can check that process still owns the terminal before a mailbox
    /// push. Without it the report is `--source=headless`: an agent that is
    /// never at a prompt (`claude -p`, `--bg`, a piped run, an old wrapper).
    static func agentLifecycleReportOptions(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let raw = environment["C11_AGENT_INTERACTIVE_PID"],
           let pid = Int32(raw.trimmingCharacters(in: .whitespaces)), pid > 1 {
            return " --pid=\(pid)"
        }
        return " --source=headless"
    }

    /// `fromNotification: true` marks an idle that only means "the agent is
    /// waiting on the operator" (a Notification or AskUserQuestion hook):
    /// the sidebar shows it as idle, but the mailbox push must not treat it as
    /// a turn end, because a paste there would answer the prompt.
    func reportAgentActivity(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String,
        activity: String,
        fromNotification: Bool = false
    ) throws {
        var options = Self.agentLifecycleReportOptions()
        if fromNotification, options.hasPrefix(" --pid=") {
            options += " --source=notification"
        }
        _ = try sendV1Command(
            "report_agent_activity \(activity) --tab=\(workspaceId) --panel=\(surfaceId)\(options)",
            client: client
        )
    }

    func clearClaudeStatus(client: SocketClient, workspaceId: String) throws {
        _ = try client.send(command: "clear_status claude_code --tab=\(workspaceId)")
    }

    func describeAskUserQuestion(_ object: [String: Any]?) -> String? {
        guard let object,
              let input = object["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              let first = questions.first else { return nil }

        var parts: [String] = []

        if let question = first["question"] as? String, !question.isEmpty {
            parts.append(question)
        } else if let header = first["header"] as? String, !header.isEmpty {
            parts.append(header)
        }

        if let options = first["options"] as? [[String: Any]] {
            let labels = options.compactMap { $0["label"] as? String }
            if !labels.isEmpty {
                parts.append(labels.map { "[\($0)]" }.joined(separator: " "))
            }
        }

        if parts.isEmpty { return "Asking a question" }
        return parts.joined(separator: "\n")
    }

    func describeToolUse(_ object: [String: Any]?) -> String? {
        guard let object, let toolName = object["tool_name"] as? String else { return nil }
        let input = object["tool_input"] as? [String: Any]

        switch toolName {
        case "Read":
            if let path = input?["file_path"] as? String {
                return "Reading \(shortenPath(path))"
            }
            return "Reading file"
        case "Edit":
            if let path = input?["file_path"] as? String {
                return "Editing \(shortenPath(path))"
            }
            return "Editing file"
        case "Write":
            if let path = input?["file_path"] as? String {
                return "Writing \(shortenPath(path))"
            }
            return "Writing file"
        case "Bash":
            if let cmd = input?["command"] as? String {
                let first = cmd.components(separatedBy: .whitespacesAndNewlines).first ?? cmd
                let short = String(first.prefix(30))
                return "Running \(short)"
            }
            return "Running command"
        case "Glob":
            if let pattern = input?["pattern"] as? String {
                return "Searching \(String(pattern.prefix(30)))"
            }
            return "Searching files"
        case "Grep":
            if let pattern = input?["pattern"] as? String {
                return "Grep \(String(pattern.prefix(30)))"
            }
            return "Searching code"
        case "Agent":
            if let desc = input?["description"] as? String {
                return String(desc.prefix(40))
            }
            return "Subagent"
        case "WebFetch":
            return "Fetching URL"
        case "WebSearch":
            if let query = input?["query"] as? String {
                return "Search: \(String(query.prefix(30)))"
            }
            return "Web search"
        default:
            return toolName
        }
    }

    func shortenPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        return name.isEmpty ? String(path.suffix(30)) : name
    }

    func resolveWorkspaceIdForClaudeHook(_ raw: String?, client: SocketClient) throws -> String {
        // C11-156: when the hook carries an explicit workspace UUID (the common
        // case — c11 exports CMUX_WORKSPACE_ID into every hook process), trust
        // it directly. `resolveWorkspaceId` short-circuits a UUID with zero
        // socket calls, but the existence-probe below added a main-thread
        // `surface.list` round-trip to EVERY hook invocation — a dominant
        // contributor to the hook-flood main-thread hang. A stale UUID is
        // harmless: downstream status/notify commands no-op on a missing
        // workspace, and falling back to the *current* focused workspace would
        // wrongly retarget another workspace's sidebar.
        if let raw, !raw.isEmpty, isUUID(raw) {
            return raw
        }
        if let raw, !raw.isEmpty, let candidate = try? resolveWorkspaceId(raw, client: client) {
            let probe = try? client.sendV2(method: "panel.list", params: ["workspace_id": candidate])
            if probe != nil {
                return candidate
            }
        }
        return try resolveWorkspaceId(nil, client: client)
    }

    /// Hooks must preserve their origin. Missing or invalid refs are never
    /// substituted with the operator's focused tab.
    func resolveSurfaceIdForClaudeHook(
        _ raw: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        guard let raw else {
            throw CLIError(message: "claude-hook requires an originating panel")
        }
        let ref = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty, isUUID(ref) || isHandleRef(ref) || Int(ref) != nil else {
            throw CLIError(message: "claude-hook requires a valid originating panel")
        }
        return try resolveSurfaceId(ref, workspaceId: workspaceId, client: client)
    }

    /// The claude-hook subcommand names the event; stdin supplies the
    /// `stop_hook_active` re-entry guard.
    func claudeMailboxHookInput(
        event: MailboxHookEvent,
        parsedInput: ClaudeHookParsedInput
    ) -> MailboxHookInput {
        var input = MailboxHookInput.parse(Data(parsedInput.rawInput.utf8))
        input.event = event
        return input
    }

    func parseClaudeHookInput(rawInput: String) -> ClaudeHookParsedInput {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            return ClaudeHookParsedInput(rawInput: rawInput, object: nil, sessionId: nil, cwd: nil, transcriptPath: nil)
        }

        let sessionId = extractClaudeHookSessionId(from: object)
        let cwd = extractClaudeHookCWD(from: object)
        let transcriptPath = firstString(in: object, keys: ["transcript_path", "transcriptPath"])
        return ClaudeHookParsedInput(rawInput: rawInput, object: object, sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath)
    }

    func extractClaudeHookSessionId(from object: [String: Any]) -> String? {
        if let id = firstString(in: object, keys: ["session_id", "sessionId"]) {
            return id
        }

        if let nested = object["notification"] as? [String: Any],
           let id = firstString(in: nested, keys: ["session_id", "sessionId"]) {
            return id
        }
        if let nested = object["data"] as? [String: Any],
           let id = firstString(in: nested, keys: ["session_id", "sessionId"]) {
            return id
        }
        if let session = object["session"] as? [String: Any],
           let id = firstString(in: session, keys: ["id", "session_id", "sessionId"]) {
            return id
        }
        if let context = object["context"] as? [String: Any],
           let id = firstString(in: context, keys: ["session_id", "sessionId"]) {
            return id
        }
        return nil
    }

    func extractClaudeHookCWD(from object: [String: Any]) -> String? {
        let cwdKeys = ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"]
        if let cwd = firstString(in: object, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["notification"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["data"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let context = object["context"] as? [String: Any],
           let cwd = firstString(in: context, keys: cwdKeys) {
            return cwd
        }
        return nil
    }

    /// C11-24: query `is_terminating_app` on `system.ping` with a 250 ms
    /// bounded timeout. CLI policy: treat unreachable/timeout as
    /// terminating so SessionEnd errs on preservation and never
    /// tombstones a ref the operator expected to resume.
    func isAppCurrentlyTerminating(
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) -> Bool {
        do {
            let response = try client.sendV2(method: "system.ping")
            if let flag = response["is_terminating_app"] as? Bool {
                if flag { telemetry.breadcrumb("claude-hook.is-terminating.true") }
                return flag
            }
            // Field absent on older builds — be conservative.
            telemetry.breadcrumb("claude-hook.is-terminating.field-absent")
            return false
        } catch let error as CLIError where isAdvisoryHookConnectivityError(error) {
            telemetry.breadcrumb("claude-hook.is-terminating.unreachable-treated-as-terminating")
            return true
        } catch {
            telemetry.breadcrumb("claude-hook.is-terminating.error-treated-as-terminating")
            return true
        }
    }

    func summarizeClaudeHookStop(
        parsedInput: ClaudeHookParsedInput,
        sessionRecord: ClaudeHookSessionRecord?
    ) -> (subtitle: String, body: String)? {
        let cwd = parsedInput.cwd ?? sessionRecord?.cwd
        let transcript = parsedInput.transcriptPath.flatMap { readTranscriptSummary(path: $0) }
        return ClaudeStopTranscript.summary(
            cwd: cwd,
            lastAssistantMessage: transcript?.lastAssistantMessage,
            fallbackBody: sessionRecord?.lastBody,
            fallbackSubtitle: sessionRecord?.lastSubtitle
        )
    }

    struct TranscriptSummary {
        let lastAssistantMessage: String?
    }

    func readTranscriptSummary(path: String) -> TranscriptSummary? {
        guard let result = ClaudeStopTranscript.read(path: path),
              let message = result.lastAssistantMessage else { return nil }
        return TranscriptSummary(lastAssistantMessage: message)
    }

    func summarizeClaudeHookNotification(rawInput: String) -> (subtitle: String, body: String) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("Waiting", "Claude is waiting for your input")
        }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            let fallback = truncate(normalizedSingleLine(trimmed), maxLength: 180)
            return classifyClaudeNotification(signal: fallback, message: fallback)
        }

        let nested = (object["notification"] as? [String: Any]) ?? (object["data"] as? [String: Any]) ?? [:]
        let signalParts = [
            firstString(in: object, keys: ["event", "event_name", "hook_event_name", "type", "kind"]),
            firstString(in: object, keys: ["notification_type", "matcher", "reason"]),
            firstString(in: nested, keys: ["type", "kind", "reason"])
        ]
        let messageCandidates = [
            firstString(in: object, keys: ["message", "body", "text", "prompt", "error", "description"]),
            firstString(in: nested, keys: ["message", "body", "text", "prompt", "error", "description"])
        ]
        let session = firstString(in: object, keys: ["session_id", "sessionId"])
        let message = messageCandidates.compactMap { $0 }.first ?? "Claude needs your input"
        let normalizedMessage = normalizedSingleLine(message)
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        var classified = classifyClaudeNotification(signal: signal, message: normalizedMessage)

        classified.body = truncate(classified.body, maxLength: 180)
        return classified
    }

    func classifyClaudeNotification(signal: String, message: String) -> (subtitle: String, body: String) {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
            let body = message.isEmpty ? "Approval needed" : message
            return ("Permission", body)
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            let body = message.isEmpty ? "Claude reported an error" : message
            return ("Error", body)
        }
        if lower.contains("complet") || lower.contains("finish") || lower.contains("done") || lower.contains("success") {
            let body = message.isEmpty ? "Task completed" : message
            return ("Completed", body)
        }
        if lower.contains("idle") || lower.contains("wait") || lower.contains("input") || lower.contains("idle_prompt") {
            let body = message.isEmpty ? "Waiting for input" : message
            return ("Waiting", body)
        }
        // Use the message directly if it's meaningful (not a generic placeholder).
        if !message.isEmpty, message != "Claude needs your input" {
            return ("Attention", message)
        }
        return ("Attention", "Claude needs your attention")
    }

    func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    func normalizedSingleLine(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
    }

    func sanitizeNotificationField(_ value: String) -> String {
        return normalizedSingleLine(value)
            .replacingOccurrences(of: "|", with: "¦")
    }
}
