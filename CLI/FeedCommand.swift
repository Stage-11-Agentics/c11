import Foundation

enum CLIHelpFlagScanner {
    static func containsHelpFlag(in arguments: [String], valueOptions: Set<String> = []) -> Bool {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if valueOptions.contains(arguments[index]) {
                index = arguments.index(index, offsetBy: 2, limitedBy: arguments.endIndex) ?? arguments.endIndex
            } else if arguments[index] == "--help" || arguments[index] == "-h" {
                return true
            } else {
                index = arguments.index(after: index)
            }
        }
        return false
    }
}

enum FeedCommand {
    static let usageText = """
    Usage: c11 feed list [--json] [--scope attention|all]
           c11 feed open <tab> [--workspace <id|ref>] [--json]
           c11 feed answer <tab> --text <text> [--workspace <id|ref>] [--by agent|operator] [--json]
           c11 feed watch [--json] [--scope attention|all]

    List, open, answer, or follow typed asks. Default scope is attention: open blocking asks and flag rows.
    --scope all also includes non-suppressed turn_end rows. Generic input is unsupported.
    feed open selects the named workspace and tab inside c11 and does not activate the app or send an answer.
    A missing workspace or tab prints unavailable and changes nothing.
    feed answer accepts only an eligible flag or turn_end row with a complete empty/suggestion prompt.
    Blocking asks, drafts, dialogs, unknown input, and cold tabs are refused. Whitespace-only text opens
    the exact tab without sending. --by defaults to agent. The result includes answered and retry; retry
    is safe only when nothing was pasted. A keypress during the 200 ms paste-settle window can leave
    the answer pasted but unsubmitted, so retry is unsafe.
    Ask prompt text appears only in this process's live list/watch JSON. It is not stored in the journal or the event log.
    A successful flag reply includes its text in the local flag.lowered event. The local EventLog
    retains an 8 MiB current file and one rolled generation; the body-free journal never receives it.
    """

    static func run(
        arguments: [String],
        jsonOutput: Bool,
        client: SocketClient,
        reconnect: () throws -> Void,
        defaultWorkspace: () -> String?,
        resolveWorkspace: (String) throws -> String?,
        resolveTab: (_ tab: String, _ workspace: String?) throws -> String?
    ) throws {
        let answerValueOptions: Set<String> = arguments.first?.lowercased() == "answer" ? ["--text"] : []
        if arguments.isEmpty || CLIHelpFlagScanner.containsHelpFlag(
            in: arguments,
            valueOptions: answerValueOptions
        ) {
            print(usageText)
            return
        }
        var args = arguments
        var json = jsonOutput
        var scan = args.startIndex
        while scan < args.endIndex {
            if args[scan] == "--text" {
                scan = args.index(scan, offsetBy: 2, limitedBy: args.endIndex) ?? args.endIndex
            } else if args[scan] == "--json" {
                json = true
                args.remove(at: scan)
            } else {
                scan = args.index(after: scan)
            }
        }
        func take(_ name: String, allowFlagValue: Bool = false) throws -> String? {
            var index = args.startIndex
            while index < args.endIndex {
                if name != "--text", args[index] == "--text" {
                    index = args.index(index, offsetBy: 2, limitedBy: args.endIndex) ?? args.endIndex
                } else if args[index] == name {
                    break
                } else {
                    index = args.index(after: index)
                }
            }
            guard index < args.endIndex else { return nil }
            let valueIndex = args.index(after: index)
            guard valueIndex < args.endIndex,
                  allowFlagValue || !args[valueIndex].hasPrefix("--") else {
                throw CLIError(message: "feed: \(name) requires a value")
            }
            let value = args[valueIndex]
            args.remove(at: valueIndex)
            args.remove(at: index)
            return value
        }
        let scopeFlag = try take("--scope")
        let scope = scopeFlag ?? FeedScope.attention.rawValue
        guard let feedScope = FeedScope(rawValue: scope) else {
            throw CLIError(message: "feed: --scope must be attention or all")
        }
        let workspaceFlag = try take("--workspace")
        let tabFlag = try take("--tab")
        guard let subcommand = args.first else {
            throw CLIError(message: "feed requires list, open, or watch")
        }
        args.removeFirst()
        switch subcommand {
        case "list":
            guard args.isEmpty, tabFlag == nil, workspaceFlag == nil else { throw CLIError(message: "usage: c11 feed list [--json] [--scope attention|all]") }
            let payload = try client.sendV2(method: "feed.list", params: ["scope": feedScope.rawValue])
            printList(payload, json: json)
        case "open":
            guard scopeFlag == nil, !args.contains(where: { $0.hasPrefix("--") }) else {
                throw CLIError(message: "usage: c11 feed open <tab> [--workspace <id|ref>] [--json]")
            }
            let tabRaw = tabFlag ?? args.first
            if tabFlag == nil { args = Array(args.dropFirst()) }
            guard let tabRaw, args.isEmpty else { throw CLIError(message: "usage: c11 feed open <tab> [--workspace <id|ref>]") }
            let workspaceRaw = workspaceFlag ?? defaultWorkspace()
            guard let workspaceRaw, let workspace = try resolveWorkspace(workspaceRaw) else {
                throw CLIError(message: "feed open requires a workspace")
            }
            guard let tab = try resolveTab(tabRaw, workspace) else {
                throw CLIError(message: "feed open requires a tab")
            }
            do {
                let payload = try client.sendV2(method: "feed.open", params: ["workspace_id": workspace, "tab_id": tab])
                if json {
                    print(jsonLine(payload))
                } else {
                    print("focused \(payload["tab_id"] as? String ?? tab)")
                }
            } catch let error as CLIError where error.message.hasPrefix("unavailable") {
                throw CLIError(message: "unavailable")
            }
        case "answer":
            guard scopeFlag == nil else { throw CLIError(message: "feed answer does not accept --scope") }
            let text = try take("--text", allowFlagValue: true)
            let actor = try take("--by") ?? "agent"
            guard actor == "agent" || actor == "operator" else {
                throw CLIError(message: "feed answer: --by must be agent or operator")
            }
            guard !args.contains(where: { $0.hasPrefix("--") }) else {
                throw CLIError(message: "feed answer: unknown flag")
            }
            guard let text else { throw CLIError(message: "usage: c11 feed answer <tab> --text <text> [--workspace <id|ref>] [--by agent|operator] [--json]") }
            guard !(tabFlag != nil && !args.isEmpty) else {
                throw CLIError(message: "feed answer accepts one tab target")
            }
            let tabRaw = tabFlag ?? args.first
            if tabFlag == nil { args = Array(args.dropFirst()) }
            guard let tabRaw, args.isEmpty else {
                throw CLIError(message: "usage: c11 feed answer <tab> --text <text> [--workspace <id|ref>] [--by agent|operator] [--json]")
            }
            let workspaceRaw = workspaceFlag ?? defaultWorkspace()
            guard let workspaceRaw, let workspace = try resolveWorkspace(workspaceRaw) else {
                throw CLIError(message: "feed answer requires a workspace")
            }
            guard let tab = try resolveTab(tabRaw, workspace) else {
                throw CLIError(message: "feed answer requires a tab")
            }
            let payload: [String: Any]
            do {
                payload = try client.sendV2(method: "feed.answer", params: [
                    "workspace_id": workspace,
                    "tab_id": tab,
                    "text": text,
                    "by": actor,
                ])
            } catch let error as CLIError where error.structuredResponse != nil {
                if json, let structured = error.structuredResponse {
                    print(jsonLine(structured))
                    fflush(stdout)
                    throw CLIError(message: error.message)
                }
                let code = ((error.structuredResponse?["error"] as? [String: Any])?["code"] as? String)
                if code == "input_guard_refused" {
                    throw CLIError(message: "\(error.message)\nUse `c11 feed open <tab>` to inspect or resolve the prompt before answering.")
                }
                throw error
            }
            if json {
                print(jsonLine(payload))
                fflush(stdout)
            } else {
                let answered = payload["answered"] as? Bool ?? false
                let submitted = payload["submitted"] as? Bool ?? false
                let retry = payload["retry"] as? String ?? "unknown"
                if payload["opened"] as? Bool == true {
                    print("opened \((payload["tab_id"] as? String) ?? tab); delivered: false")
                } else {
                    print("answered: \(answered)  submitted: \(submitted)  retry: \(retry)")
                }
                fflush(stdout)
            }
        case "watch":
            guard args.isEmpty, tabFlag == nil, workspaceFlag == nil else {
                throw CLIError(message: "usage: c11 feed watch [--json] [--scope attention|all]")
            }
            guard scopeFlag == nil || FeedScope(rawValue: scope) != nil else {
                throw CLIError(message: "feed: --scope must be attention or all")
            }
            try watch(client: client, scope: feedScope, json: json, reconnect: reconnect)
        default:
            throw CLIError(message: "feed: unknown command '\(subcommand)'")
        }
    }

    /// Best-effort display note. Failures are ignored and never spooled.
    static func sendDisplayNote(
        client: SocketClient,
        workspaceID: String,
        tabID: String,
        sessionID: String?,
        eventID: String,
        requestID: String?,
        prompt: String?,
        options: [String]?,
        deadline: TimeInterval
    ) {
        guard deadline > 0, let sessionID, !sessionID.isEmpty else { return }
        var params: [String: Any] = [
            "workspace_id": workspaceID,
            "tab_id": tabID,
            "agent_kind": "claude-code",
            "session_id": sessionID,
            "event_id": eventID,
        ]
        if let requestID { params["request_id"] = requestID }
        if let prompt { params["prompt"] = prompt }
        if let options { params["options"] = options }
        do {
            _ = try client.sendV2(method: "feed.note_display", params: params, deadline: .custom(deadline))
        } catch {
            return
        }
    }

    private static func printList(_ payload: [String: Any], json: Bool) {
        if json {
            print(jsonLine(payload))
            fflush(stdout)
            return
        }
        let rows = payload["rows"] as? [[String: Any]] ?? []
        if rows.isEmpty {
            print("No feed rows.")
            fflush(stdout)
            return
        }
        for row in rows {
            let kind = (row["kind"] as? String) ?? "-"
            let state = (row["state"] as? String) ?? "-"
            let flag = (row["flag"] as? [String: Any])?["reason"] as? String
            let prompt = (row["prompt_available"] as? Bool) == true ? "prompt" : "no-prompt"
            let flagPart = flag.map { "flag=\($0)" } ?? "no-flag"
            let workspace = row["workspace_id"] as? String ?? ""
            let tab = row["tab_id"] as? String ?? ""
            print("\(workspace)  \(tab)  \(kind)  \(state)  \(flagPart)  \(prompt)")
        }
        fflush(stdout)
    }

    private static func watch(client: SocketClient, scope: FeedScope, json: Bool, reconnect: () throws -> Void) throws {
        var parser = FeedWatchParser()
        var listed = try client.sendV2(method: "feed.list", params: ["scope": scope.rawValue])
        var instance = listed["instance"] as? String
        var logURL = try logURL(for: instance)
        var offset = fileSize(logURL) ?? 0
        var missingAnnounced = logURL == nil
        printList(listed, json: json)
        let refreshed = try client.sendV2(method: "feed.list", params: ["scope": scope.rawValue])
        if refreshed["instance"] as? String != instance {
            printContinuity()
            rebind(refreshed, parser: &parser, instance: &instance, logURL: &logURL, offset: &offset, missingAnnounced: &missingAnnounced)
            printList(refreshed, json: json)
        } else if jsonLine(refreshed["rows"] ?? []) != jsonLine(listed["rows"] ?? []) {
            printList(refreshed, json: json)
        }
        listed = refreshed
        var lastPoll = Date()
        var socketDown = false
        while true {
            autoreleasepool {
                if let url = logURL {
                    let size = fileSize(url)
                    if size == nil {
                        if !missingAnnounced {
                            printContinuity()
                            missingAnnounced = true
                        }
                    } else if let size, size < offset {
                        printContinuity()
                        offset = 0
                        parser = FeedWatchParser()
                        missingAnnounced = false
                    } else if let size, size > offset, let data = read(url, from: offset),
                              let chunk = String(data: data, encoding: .utf8) {
                        offset += UInt64(data.count)
                        missingAnnounced = false
                        for signal in parser.consume(chunk) {
                            switch signal {
                            case .continuityUnavailable:
                                printContinuity()
                                if let next = try? client.sendV2(method: "feed.list", params: ["scope": scope.rawValue]) {
                                    if next["instance"] as? String != instance {
                                        rebind(next, parser: &parser, instance: &instance, logURL: &logURL, offset: &offset, missingAnnounced: &missingAnnounced)
                                    }
                                    printList(next, json: json)
                                    listed = next
                                }
                            case .followedEvent:
                                if let next = try? client.sendV2(method: "feed.list", params: ["scope": scope.rawValue]) {
                                    if next["instance"] as? String != instance {
                                        printContinuity()
                                        rebind(next, parser: &parser, instance: &instance, logURL: &logURL, offset: &offset, missingAnnounced: &missingAnnounced)
                                        printList(next, json: json)
                                    } else if jsonLine(next["rows"] ?? []) != jsonLine(listed["rows"] ?? []) {
                                        printList(next, json: json)
                                    }
                                    listed = next
                                }
                            }
                        }
                    }
                }
                if Date().timeIntervalSince(lastPoll) >= 1 {
                    lastPoll = Date()
                    do {
                        if socketDown {
                            try reconnect()
                            let next = try client.sendV2(method: "feed.list", params: ["scope": scope.rawValue])
                            rebind(next, parser: &parser, instance: &instance, logURL: &logURL, offset: &offset, missingAnnounced: &missingAnnounced)
                            printList(next, json: json)
                            listed = next
                            socketDown = false
                        }
                        let next = try client.sendV2(method: "feed.list", params: ["scope": scope.rawValue])
                        socketDown = false
                        if next["instance"] as? String != instance {
                            printContinuity()
                            rebind(next, parser: &parser, instance: &instance, logURL: &logURL, offset: &offset, missingAnnounced: &missingAnnounced)
                            printList(next, json: json)
                        } else if jsonLine(next["rows"] ?? []) != jsonLine(listed["rows"] ?? []) {
                            printList(next, json: json)
                        }
                        listed = next
                    } catch {
                        if !socketDown {
                            printContinuity()
                            socketDown = true
                        }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private static func rebind(
        _ payload: [String: Any],
        parser: inout FeedWatchParser,
        instance: inout String?,
        logURL: inout URL?,
        offset: inout UInt64,
        missingAnnounced: inout Bool
    ) {
        instance = payload["instance"] as? String
        parser = FeedWatchParser()
        logURL = try? self.logURL(for: instance)
        offset = fileSize(logURL) ?? 0
        missingAnnounced = logURL == nil
    }

    private static func logURL(for instance: String?) throws -> URL? {
        guard let instance, !instance.isEmpty else { return nil }
        let state = try EventLogLayout.defaultStateURL()
        return EventLogLayout.logURL(state: state, instance: instance)
    }

    private static func fileSize(_ url: URL?) -> UInt64? {
        guard let url else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private static func read(_ url: URL, from offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return (try? handle.readToEnd()) ?? Data()
    }

    private static func printContinuity() {
        print("{\"continuity\":\"unavailable\"}")
        fflush(stdout)
    }

    private static func jsonLine(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
