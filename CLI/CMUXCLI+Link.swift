import Foundation

extension CMUXCLI {
    struct LinkArguments {
        enum Format: String { case url, markdown, osc8 }
        let panel: String?
        let workspace: String?
        let format: Format
    }

    /// Called before discovery: a malformed link request never contacts c11.
    func parseLinkArguments(_ args: [String]) throws -> LinkArguments {
        var values: [String: String] = [:]
        var index = 0
        while index < args.count {
            let raw = args[index]
            if raw == "--json" || raw == "--" {
                index += 1
                continue
            }
            let name = Self.flagSpellings("--panel").contains(raw) ? "--panel" : raw
            guard ["--panel", "--workspace", "--format"].contains(name) else {
                throw CLIError(message: unexpectedArgumentMessage(command: "link", argument: raw))
            }
            guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else {
                throw CLIError(message: requiresValueMessage(command: "link", flag: name))
            }
            guard values[name] == nil else {
                throw CLIError(message: String(format: String(localized: "cli.link.optionRepeated", defaultValue: "link: %@ may only be supplied once"), name))
            }
            let value = args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw CLIError(message: String(format: String(localized: "cli.link.optionEmpty", defaultValue: "link: %@ received an empty value"), name))
            }
            values[name] = value
            index += 2
        }
        guard values["--panel"] != nil || values["--workspace"] != nil else {
            throw CLIError(message: String(localized: "cli.link.targetRequired", defaultValue: "link requires --panel or --workspace; no current target is assumed"))
        }
        guard let format = LinkArguments.Format(rawValue: values["--format"] ?? "url") else {
            throw CLIError(message: String(localized: "cli.link.formatInvalid", defaultValue: "link: --format must be url, markdown, or osc8"))
        }
        for name in ["--panel", "--workspace"] {
            guard let raw = values[name] else { continue }
            let kind = name == "--panel" ? "panel" : "workspace"
            let canonical = Self.canonicalHandle(raw).lowercased()
            let parts = canonical.split(separator: ":", omittingEmptySubsequences: false)
            let isRef = parts.count == 2 && parts[0] == kind && Int(parts[1]).map { $0 > 0 } == true
            guard isUUID(raw) || isRef || Int(raw).map({ $0 >= 0 }) == true else {
                let format = kind == "panel"
                    ? String(localized: "cli.link.targetInvalid.panel", defaultValue: "link: invalid panel target '%@'; use a UUID, ref, or index")
                    : String(localized: "cli.link.targetInvalid.workspace", defaultValue: "link: invalid workspace target '%@'; use a UUID, ref, or index")
                throw CLIError(message: String(format: format, raw))
            }
        }
        return LinkArguments(panel: values["--panel"], workspace: values["--workspace"], format: format)
    }

    func runLink(arguments: LinkArguments, client: SocketClient, jsonOutput: Bool) throws {
        #if DEBUG
        CLIFlagReadLog.read(["--panel", "--workspace", "--format"])
        #endif
        func matches(_ item: [String: Any], _ raw: String) -> Bool {
            if let id = item["id"] as? String, id.caseInsensitiveCompare(raw) == .orderedSame { return true }
            if let ref = item["ref"] as? String,
               Self.canonicalHandle(ref).caseInsensitiveCompare(Self.canonicalHandle(raw)) == .orderedSame { return true }
            return Int(raw).map { intFromAny(item["index"]) == $0 } == true
        }
        func uuid(_ item: [String: Any]) throws -> UUID {
            guard let raw = item["id"] as? String, let id = UUID(uuidString: raw) else {
                throw CLIError(message: String(localized: "cli.link.inventoryInvalid", defaultValue: "link: c11 returned an invalid target identity"))
            }
            return id
        }
        // One string per kind: translations cannot inflect a substituted English word.
        func targetError(kind: PanelLinkFormat.Kind, raw: String, ambiguous: Bool = false) -> CLIError {
            if ambiguous {
                let format = kind == .panel
                    ? String(localized: "cli.link.targetAmbiguous.panel", defaultValue: "link: panel target '%@' is ambiguous; use a UUID, ref, or narrower scope")
                    : String(localized: "cli.link.targetAmbiguous.workspace", defaultValue: "link: workspace target '%@' is ambiguous; use a UUID, ref, or narrower scope")
                return CLIError(message: String(format: format, raw))
            }
            let format = kind == .panel
                ? String(localized: "cli.link.targetNotFound.panel", defaultValue: "link: panel target '%@' is not available in the requested scope")
                : String(localized: "cli.link.targetNotFound.workspace", defaultValue: "link: workspace target '%@' is not available in the requested scope")
            return CLIError(message: "not_found: " + String(format: format, raw))
        }

        let windows: [[String: Any]]
        if let window = client.scopedWindow {
            windows = [["id": window]]
        } else {
            let payload = try client.sendV2(method: "window.list")
            windows = payload["windows"] as? [[String: Any]] ?? []
        }
        var workspaces: [(item: [String: Any], windowID: String)] = []
        for window in windows {
            let windowID = try uuid(window).uuidString.lowercased()
            let payload = try client.sendV2(method: "workspace.list", params: ["window_id": windowID])
            for item in payload["workspaces"] as? [[String: Any]] ?? [] {
                if arguments.workspace.map({ matches(item, $0) }) ?? true {
                    workspaces.append((item, windowID))
                }
            }
        }
        if let workspace = arguments.workspace, workspaces.count != 1 {
            throw targetError(kind: .workspace, raw: workspace, ambiguous: workspaces.count > 1)
        }

        let target: [String: Any]
        let workspace: [String: Any]
        let windowID: String
        let kind: PanelLinkFormat.Kind
        if let panel = arguments.panel {
            var found: [(panel: [String: Any], workspace: [String: Any], windowID: String)] = []
            for candidate in workspaces {
                let workspaceID = try uuid(candidate.item).uuidString.lowercased()
                let payload = try client.sendV2(method: "panel.list", params: ["window_id": candidate.windowID, "workspace_id": workspaceID])
                for item in payload["panels"] as? [[String: Any]] ?? [] where matches(item, panel) {
                    found.append((item, candidate.item, candidate.windowID))
                }
            }
            guard found.count == 1, let destination = found.first else {
                throw targetError(kind: .panel, raw: panel, ambiguous: found.count > 1)
            }
            target = destination.panel
            workspace = destination.workspace
            windowID = destination.windowID
            kind = .panel
        } else {
            guard let destination = workspaces.first, let workspaceRef = arguments.workspace else {
                throw CLIError(message: String(localized: "cli.link.targetRequired", defaultValue: "link requires --panel or --workspace; no current target is assumed"))
            }
            guard workspaces.count == 1 else { throw targetError(kind: .workspace, raw: workspaceRef, ambiguous: true) }
            target = destination.item
            workspace = destination.item
            windowID = destination.windowID
            kind = .workspace
        }

        let link = PanelLinkFormat(kind: kind, id: try uuid(target), title: target["title"] as? String ?? "")
        if jsonOutput {
            let workspaceLink = PanelLinkFormat(kind: .workspace, id: try uuid(workspace), title: workspace["title"] as? String ?? "")
            // UUIDs stay UUIDs regardless of --id-format: links are durable identity.
            let payload: [String: Any] = [
                "kind": kind.rawValue,
                "id": link.id.uuidString.lowercased(),
                "ref": target["ref"] as? String ?? "",
                "title": link.title,
                "window_id": windowID,
                "workspace": ["id": workspaceLink.id.uuidString.lowercased(), "ref": workspace["ref"] as? String ?? "", "title": workspaceLink.title],
                "url": link.url,
                "markdown": link.markdown,
                "osc8": link.osc8,
            ]
            print(jsonString(payload))
        } else {
            switch arguments.format {
            case .url: print(link.url)
            case .markdown: print(link.markdown)
            case .osc8: print(link.osc8)
            }
        }
    }
}
