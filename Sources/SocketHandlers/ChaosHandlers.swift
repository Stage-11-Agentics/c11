import Foundation

// `chaos.draw` / `chaos.cast` (C11H-199): the Chaos Wizard from the CLI.
// Off-main per the socket threading policy: deck and folder I/O, then one
// `agent.launch` call per piece, each of which hops to main only for creation.
extension TerminalController {
    nonisolated func v2Chaos(method: String, params: [String: Any]) -> V2CallResult {
        let modeRaw = (v2RawString(params, "mode") ?? ChaosMode.two.rawValue).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = ChaosMode(rawValue: modeRaw) else {
            return .err(code: "invalid_params", message: "mode must be one of: two, four, ensemble, one", data: nil)
        }
        var seed: UInt64?
        if let raw = params["seed"] {
            let parsed: UInt64? = {
                if let s = raw as? String { return UInt64(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if let n = raw as? NSNumber, n.int64Value > 0 { return n.uint64Value }
                return nil
            }()
            guard let parsed, parsed > 0 else {
                return .err(code: "invalid_params", message: "seed must be a positive integer", data: nil)
            }
            seed = parsed
        }
        let drawn = ChaosCaster.draw(mode: mode, seed: seed)
        guard drawn.pieces.count == mode.pieceCount else {
            return .err(code: "chaos_deck_empty", message: "The Chaos deck has no premises, media or constraints to draw from", data: nil)
        }
        let plan = ChaosCaster.plan(mode: mode, seed: drawn.seed, pieces: drawn.pieces)
        switch method {
        case "chaos.draw":
            return .ok(plan.json(includePrompts: v2Bool(params, "prompts") ?? false))
        case "chaos.cast":
            if v2Bool(params, "dry_run") == true {
                var out = plan.json(includePrompts: true)
                out["dry_run"] = true
                return .ok(out)
            }
            let windowRef = (v2RawString(params, "window_id")?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            // The calling panel becomes each agent's creator (lineage), never a focus target.
            let caller = (v2RawString(params, "caller_surface_id") ?? v2RawString(params, "caller_panel_id"))
                .flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
            // Socket callers never switch the operator's workspace; the cast lands in the background.
            let outcome = ChaosCaster.cast(plan, controller: self, windowRef: windowRef, callerPanelId: caller, select: false)
            if let error = outcome.error, outcome.launched.isEmpty {
                return .err(code: error.code, message: error.message, data: outcome.json())
            }
            // A partial cast answers with the outcome (its workspace, run and
            // launched panels) so the caller can finish or clean up; `partial`
            // and `error` say it stopped, and the CLI exits non-zero.
            var out = outcome.json()
            out["partial"] = outcome.error != nil
            return .ok(out)
        default:
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
    }
}
