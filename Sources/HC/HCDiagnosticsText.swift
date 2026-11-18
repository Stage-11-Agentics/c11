import Foundation

/// The text form of the `hc.diagnostics` reply, shared by the `hc-diagnostics`
/// CLI command and its tests. Pure: it only reads the decoded reply.
enum HCDiagnosticsText {
    static let shardFields = [
        "session", "index", "core_id", "holder_pid", "last_lost_holder_pid",
        "readiness", "readiness_reason", "connection_generation", "sequence",
        "terminals", "ended", "remote_terminals", "remote_ended", "holder_lost_count",
    ]
    static let panelFields = [
        "panel_id", "terminal", "machine", "tty", "pid", "root", "lifecycle",
        "persistence", "serving_build", "configured_build", "reason", "shard",
    ]

    static let abandonedFields = ["session", "terminals", "terminals_left", "processes", "unverified"]

    static func lines(_ response: [String: Any]) -> [String] {
        var out: [String] = []
        if let version = response["c11_version"] as? String {
            out.append("c11_version=\(version)")
        }
        let count = response["holder_lost_count"] as? Int ?? 0
        out.append("holder_lost_count=\(count)")
        if let error = response["holder_lost_count_error"] as? String {
            out.append("holder_lost_count_error=\(error)")
        }
        // C11H-235: local terminals still rooted at `/usr/bin/login` (opened by
        // a build before C11H-232), the ones a stray `pkill -f <x> -n` matches.
        if let rooted = response["login_rooted"] as? Int {
            out.append("login_rooted=\(rooted)")
        }
        for key in ["readiness", "readiness_reason", "connection_generation", "sequence"] {
            guard let value = response[key], !(value is NSNull) else { continue }
            out.append("\(key)=\(value)")
        }
        // One line per shard: which session, which core, which holder, how many
        // of its own terminals (and other machines' mirrors, apart), and that
        // shard's own holder-loss count. Legacy shard 0 is marked, so a kill
        // reads as one shard's.
        for shard in response["shards"] as? [[String: Any]] ?? [] {
            var parts = ["shard"]
            parts += fields(shardFields, in: shard)
            // Several holders at once (an old one outliving a recovery): list all.
            if let holders = shard["holder_pids"] as? [Int], holders.count > 1 {
                parts.append("holder_pids=" + holders.map(String.init).joined(separator: ","))
            }
            if shard["legacy"] as? Bool == true { parts.append("legacy=true") }
            out.append(parts.joined(separator: " "))
        }
        for panel in response["panels"] as? [[String: Any]] ?? [] {
            out.append(fields(panelFields, in: panel).joined(separator: " "))
        }
        // C11H-352: hc sessions whose core and holder are gone, one line each,
        // with what their terminals left running (`c11-core abandoned` lists
        // the processes, `c11-core end-abandoned <session>` ends them).
        if let processes = response["abandoned_processes"] as? Int {
            out.append("abandoned_processes=\(processes)")
        }
        if let unreadable = response["abandoned_unreadable"] as? Int, unreadable > 0 {
            out.append("abandoned_unreadable=\(unreadable)")
        }
        for session in response["abandoned_sessions"] as? [[String: Any]] ?? [] {
            out.append((["abandoned"] + fields(abandonedFields, in: session)).joined(separator: " "))
        }
        return out
    }

    private static func fields(_ keys: [String], in object: [String: Any]) -> [String] {
        keys.compactMap { key -> String? in
            guard let value = object[key], !(value is NSNull) else { return nil }
            return "\(key)=\(value)"
        }
    }
}
