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

    struct AgentsArgs {
        var bundleID: String?
        var json: Bool
    }

    func parseAgentsArgs(_ args: [String], jsonOutput: Bool) throws -> AgentsArgs {
        var bundleID: String?
        var json = jsonOutput
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--json":
                json = true
            case "--bundle-id":
                guard bundleID == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw CLIError(message: "--bundle-id requires a value")
                }
                bundleID = args[index + 1]
                index += 1
            default:
                throw CLIError(message: "Unknown agents argument '\(arg)'. Run 'c11 agents --help' for usage.")
            }
            index += 1
        }
        return AgentsArgs(bundleID: bundleID, json: json)
    }

    func runAgentsLive(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let parsed = try parseAgentsArgs(commandArgs, jsonOutput: jsonOutput)
        let brand = try client.sendV2(method: "system.brand")
        let identifier = ((brand["bundle"] as? [String: Any])?["identifier"] as? String) ?? ""
        if let requested = parsed.bundleID, requested != identifier {
            throw CLIError(message: "bundle id does not match the running app")
        }
        let payload = try client.sendV2(method: "agents.list")
        printAgents(payload, json: parsed.json)
    }

    func runAgentsOffline(commandArgs: [String], jsonOutput: Bool) throws {
        let parsed = try parseAgentsArgs(commandArgs, jsonOutput: jsonOutput)
        guard let bundleID = parsed.bundleID else {
            printAgents(AgentRoster.unavailableDocument(), json: parsed.json)
            return
        }
        let layout: JournalStorageLayout
        do {
            layout = try JournalStorageLayout.resolve(bundleID: bundleID)
        } catch {
            throw CLIError(message: "invalid bundle id")
        }
        guard FileManager.default.fileExists(atPath: layout.database.path) else {
            printAgents(AgentRoster.unavailableDocument(), json: parsed.json)
            return
        }
        let document: [String: Any]
        do {
            let store = try JournalStore(layout: layout, readOnly: true)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let currents = try store.listCurrent().map(JournalReplayPolicy.restored)
            let unattributed = try store.unattributedCount()
            let coverage = try store.coverage()
            var events: [String: [AgentRoster.RetainedEvent]] = [:]
            var truncated = Set<String>()
            for row in currents where row.isHistorical {
                let page = try store.retainedOwnerEvents(
                    owner: row.owner, throughSequence: row.lastSequence, limit: AgentRoster.restoreLimit)
                events[row.owner.key] = page.events
                if page.truncated { truncated.insert(row.owner.key) }
            }
            document = AgentRoster.document(
                live: [], currents: currents, eventsByOwner: events, truncatedOwners: truncated,
                unattributed: unattributed, storePruned: coverage.first > 1, storageAvailable: true,
                healthDegraded: false, now: now, liveIdentity: "unavailable")
        } catch {
            document = AgentRoster.unavailableDocument()
        }
        printAgents(document, json: parsed.json)
    }

    func printAgents(_ document: [String: Any], json: Bool) {
        if json {
            print(jsonString(document))
            return
        }
        let coverage = document["coverage"] as? [String: Any] ?? [:]
        let live = agentsCell(document["live_identity"])
        let health = agentsCell(coverage["health"])
        let storage = agentsCell(coverage["storage"])
        let unattributed = agentsCell(coverage["unattributed"])
        print("Agents  live=\(live)  health=\(health)  storage=\(storage)  unattributed=\(unattributed)")
        let panels = (document["panels"] ?? document["tabs"]) as? [[String: Any]] ?? []
        if panels.isEmpty {
            print("No live panels.")
        }
        for panel in panels {
            print("\(agentsCell(panel["panel_id"] ?? panel["tab_id"]))  \(agentsCell(panel["kind"]))  \(agentsCell(panel["state"]))  \(agentsCell(panel["reason"]))  \(agentsCell(panel["since"]))  \(agentsCell(panel["freshness"]))  flag=\(agentsCell(panel["flag"]))  seen=\(agentsCell(panel["last_seen_at"]))")
        }
        let candidates = document["restore_candidates"] as? [[String: Any]] ?? []
        print("Restore candidates  \(candidates.count)")
        for row in candidates {
            print("\(agentsCell(row["label"]))  \(agentsCell(row["panel_id"] ?? row["tab_id"]))  \(agentsCell(row["connection"]))  \(agentsCell(row["coverage"]))")
        }
    }

    func agentsCell(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "-" }
        return String(describing: value)
    }
}
