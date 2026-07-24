// ConfigHandlers.swift
//
// Socket `config.*` domain (C11-180, design §6). The programmatic twin of the
// `c11 config` CLI: reads/mutations operate on the state-root files through the
// shared `ConfigCommandCore`, and `config.launch` is a thin client over
// `agent.launch` (`v2AgentLaunch`) — one launch composer, reusing
// `AgentLaunchPlanner`'s error codes and recording `source=socket` + config id.
//
// Threading (socket policy): the eight read/mutation methods are file I/O with
// no AppKit touch → registered in `TerminalController.socketWorkerV2Methods` and
// executed off-main by `socketWorkerV2Response`. `config.launch` alone creates a
// surface, so it runs on the main actor via `v2DispatchExtracted` →
// `v2DispatchConfig`.

import Foundation

extension ConfigCommandCore {
    /// Map a saved config → the `AgentLaunchRequest` the planner consumes.
    /// `promptOverride` (the launch-time `--prompt`/`--prompt-file`) wins over
    /// the config's own `initialPrompt`; `command`/`env` ride the request so
    /// `config launch` honors the full §1.3 recipe while reusing the planner's
    /// error codes verbatim. App-only (`AgentLaunchRequest` is a c11-target
    /// type); the shared core stays free of it to keep the CLI/app boundary.
    static func buildLaunchRequest(
        from saved: SavedAgentConfig,
        promptOverride: String?,
        task: String? = nil
    ) -> AgentLaunchRequest {
        let cfg = saved.config
        let prompt = promptOverride?.nonEmpty ?? cfg.initialPrompt?.nonEmpty
        return AgentLaunchRequest(
            kind: cfg.harness,
            model: cfg.model,
            effort: cfg.effort,
            task: task,
            prompt: prompt,
            systemPrompt: cfg.systemPrompt,
            extraEnv: cfg.env ?? [:],
            commandOverride: cfg.command
        )
    }
}

extension TerminalController {

    /// Main-actor router for the `config.*` domain. Only `config.launch` needs
    /// the main actor (surface creation); the read/mutation methods are handled
    /// off-main via `socketWorkerV2Response` and should never reach here, but we
    /// answer them defensively (they are pure file I/O) so a routing change can't
    /// silently 404 them.
    func v2DispatchConfig(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "config.launch":
            return v2Result(id: id, v2ConfigLaunch(params: params))
        case "config.list", "config.recent", "config.stats",
             "config.save", "config.edit", "config.rm", "config.reorder", "config.default":
            return v2Result(id: id, Self.v2ConfigNonLaunch(method: method, params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    // MARK: - Off-main read/mutation dispatch (called from socketWorkerV2Response)

    /// Pure, AppKit-free handling of every non-launch `config.*` method. Static +
    /// nonisolated so `socketWorkerV2Response` runs it off the main actor.
    nonisolated static func v2ConfigNonLaunch(method: String, params: [String: Any]) -> V2CallResult {
        let core = ConfigCommandCore()
        do {
            switch method {
            case "config.list":
                return .ok(core.list().jsonObject())
            case "config.recent":
                return .ok(core.recent().jsonObject())
            case "config.stats":
                let window = try ConfigCommandCore.parseWindow(params["window"] as? String)
                let axis = try ConfigCommandCore.parseAxis(params["by"] as? String)
                return .ok(core.statsView(window: window, by: axis).jsonObject())
            case "config.save":
                guard let name = (params["name"] as? String)?.nonEmpty else {
                    return .err(code: "invalid_params", message: "config.save requires 'name'", data: nil)
                }
                let saved = try core.save(name: name, fields: configFields(params))
                return .ok(try ConfigJSON.object(from: saved))
            case "config.edit":
                guard let ref = (params["config"] as? String)?.nonEmpty else {
                    return .err(code: "invalid_params", message: "config.edit requires 'config' (name|id)", data: nil)
                }
                let saved = try core.edit(nameOrId: ref, fields: configFields(params))
                return .ok(try ConfigJSON.object(from: saved))
            case "config.rm":
                guard let ref = (params["config"] as? String)?.nonEmpty else {
                    return .err(code: "invalid_params", message: "config.rm requires 'config' (name|id)", data: nil)
                }
                let removed = try core.remove(nameOrId: ref)
                return .ok(["removed": try ConfigJSON.object(from: removed)])
            case "config.reorder":
                guard let ref = (params["config"] as? String)?.nonEmpty else {
                    return .err(code: "invalid_params", message: "config.reorder requires 'config' (name|id)", data: nil)
                }
                guard let to = intParam(params, "to") else {
                    return .err(code: "invalid_params", message: "config.reorder requires integer 'to'", data: nil)
                }
                let moved = try core.reorder(nameOrId: ref, to: to)
                return .ok(try ConfigJSON.object(from: moved))
            case "config.default":
                if boolParam(params, "follow_recent") {
                    try core.setFollowRecent()
                    return .ok(["mode": "follow-recent"])
                }
                if boolParam(params, "pin_current") {
                    let saved = try core.pinCurrent(name: (params["name"] as? String)?.nonEmpty)
                    return .ok(["pinned": try ConfigJSON.object(from: saved)])
                }
                guard let ref = (params["config"] as? String)?.nonEmpty else {
                    return .err(code: "invalid_params", message: "config.default requires 'config' (name|id), 'follow_recent', or 'pin_current'", data: nil)
                }
                let saved = try core.setDefault(nameOrId: ref)
                return .ok(["pinned": try ConfigJSON.object(from: saved)])
            default:
                return .err(code: "method_not_found", message: "Unknown method", data: nil)
            }
        } catch let e as ConfigCoreError {
            return .err(code: e.code, message: e.message, data: nil)
        } catch {
            return .err(code: "config_error", message: "\(error)", data: nil)
        }
    }

    // MARK: - config.launch (main actor; thin client over agent.launch)

    /// Resolve a saved config by name|id, translate its full recipe into
    /// `agent.launch` params, and delegate to `v2AgentLaunch` — so error codes,
    /// placement, identity stamp, and stats recording are all the one composer.
    func v2ConfigLaunch(params: [String: Any]) -> V2CallResult {
        guard let ref = (params["config"] as? String)?.nonEmpty else {
            return .err(code: "invalid_params", message: "config.launch requires 'config' (name|id)", data: nil)
        }
        let core = ConfigCommandCore()
        let saved: SavedAgentConfig
        do {
            saved = try core.resolveConfig(nameOrId: ref)
        } catch let e as ConfigCoreError {
            return .err(code: e.code, message: e.message, data: nil)
        } catch {
            return .err(code: "config_error", message: "\(error)", data: nil)
        }

        let inputs: ConfigLaunchInputs
        do {
            inputs = try ConfigCommandCore.parseLaunchInputs(
                nameOrId: ref,
                pane: params["pane_id"] as? String ?? params["pane"] as? String,
                workspace: params["workspace_id"] as? String ?? params["workspace"] as? String,
                newWorkspace: boolParam(params, "new_workspace"),
                cwd: params["cwd"] as? String,
                prompt: params["prompt"] as? String,
                promptFile: nil,
                promptFileContents: nil,
                json: boolParam(params, "json")
            )
        } catch let e as ConfigCoreError {
            return .err(code: e.code, message: e.message, data: nil)
        } catch {
            return .err(code: "config_error", message: "\(error)", data: nil)
        }

        // Translate the saved config's full recipe into agent.launch params via
        // the one tested mapping (`buildLaunchRequest`), so config→launch is
        // single-sourced. `v2AgentLaunch` re-derives the same request from these
        // params — one launch composer, reusing AgentLaunchPlanner's error codes.
        let request = ConfigCommandCore.buildLaunchRequest(from: saved, promptOverride: inputs.prompt)
        var launchParams: [String: Any] = ["type": request.kind]
        if let m = request.model?.nonEmpty { launchParams["model"] = m }
        if let e = request.effort?.nonEmpty { launchParams["effort"] = e }
        if let sp = request.systemPrompt {
            launchParams["system_prompt_mode"] = sp.mode.rawValue
            launchParams["system_prompt"] = sp.text
        }
        if let command = request.commandOverride?.nonEmpty { launchParams["command_override"] = command }
        if !request.extraEnv.isEmpty { launchParams["env"] = request.extraEnv }
        if let prompt = request.prompt?.nonEmpty { launchParams["prompt"] = prompt }
        switch inputs.placement {
        case .newWorkspace: launchParams["new_workspace"] = true
        case .pane(let p): launchParams["pane_id"] = p
        case .workspace(let w): launchParams["workspace_id"] = w
        case .defaultPlacement: break
        }
        if let cwd = inputs.cwd { launchParams["cwd"] = cwd }
        launchParams["config_id"] = saved.id
        launchParams["source"] = AgentLaunchSource.socket.rawValue
        if params["focus"] != nil { launchParams["focus"] = params["focus"] }

        return v2AgentLaunch(params: launchParams)
    }

    // MARK: - nonisolated param helpers

    /// Build `ConfigFields` from a socket param dict (save/edit). Keys mirror the
    /// CLI flags with `-`→`_`. `nil` = not supplied (edit keeps base); empty
    /// string = clear to inherit.
    nonisolated static func configFields(_ params: [String: Any]) -> ConfigFields {
        var env: [String: String]?
        if let raw = params["env"] as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in raw { if let s = v as? String { out[k] = s } }
            env = out
        } else if let raw = params["env"] as? [String: String] {
            env = raw
        }
        return ConfigFields(
            harness: params["harness"] as? String,
            model: params["model"] as? String,
            effort: params["effort"] as? String,
            systemPromptMode: params["system_prompt_mode"] as? String,
            systemPromptText: params["system_prompt"] as? String,
            command: params["command"] as? String,
            initialPrompt: params["initial_prompt"] as? String,
            env: env
        )
    }

    nonisolated static func intParam(_ params: [String: Any], _ key: String) -> Int? {
        if let i = params[key] as? Int { return i }
        if let n = params[key] as? NSNumber { return n.intValue }
        if let s = params[key] as? String { return Int(s) }
        return nil
    }
}

/// Free helper (nonisolated, usable from both the static + instance handlers).
func boolParam(_ params: [String: Any], _ key: String) -> Bool {
    if let b = params[key] as? Bool { return b }
    if let n = params[key] as? NSNumber { return n.boolValue }
    if let s = params[key] as? String {
        return ["1", "true", "yes", "on"].contains(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    return false
}
