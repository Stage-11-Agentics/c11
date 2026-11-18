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
// executed off-main by `socketWorkerV2Response`. `config.launch` joins that
// worker path because its delegated `agent.launch` performs config + git I/O;
// both short-hop to main only for bounded snapshots and surface creation.

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
        let rawPrompt = promptOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? promptOverride : cfg.initialPrompt
        let prompt = rawPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? rawPrompt : nil
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

    /// Main-actor fallback router for the `config.*` domain. Every config method,
    /// including launch planning, is normally handled by `socketWorkerV2Response`;
    /// launch itself hops to main only for bounded snapshots and creation.
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
                if boolParam(params, "pin_current") {
                    let saved = try core.pinCurrent(name: (params["name"] as? String)?.nonEmpty)
                    return .ok(["pinned": try ConfigJSON.object(from: saved)])
                }
                guard let ref = (params["config"] as? String)?.nonEmpty else {
                    return .err(code: "invalid_params", message: "config.default requires 'config' (name|id) or 'pin_current'", data: nil)
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

    // MARK: - config.launch (socket worker; thin client over agent.launch)

    /// Resolve a saved config by name|id, translate its full recipe into
    /// `agent.launch` params, and delegate to `v2AgentLaunch` — so error codes,
    /// placement, identity stamp, and stats recording are all the one composer.
    nonisolated func v2ConfigLaunch(params: [String: Any]) -> V2CallResult {
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
        // Caller, delegation and title ride along; ChaosCaster does not use this
        // function (it calls `agentLaunchParams` and `v2AgentLaunch` itself).
        switch Self.makeConfigLaunchParams(saved: saved, inputs: inputs, socketParams: params) {
        case .failure(let error):
            return .err(code: error.code, message: error.message, data: nil)
        case .success(let launchParams):
            return v2AgentLaunch(params: launchParams)
        }
    }

    /// Placement, cwd, machine, source, caller, delegation and title for one
    /// `config.launch`. The saved recipe stays in `agentLaunchParams`.
    nonisolated static func makeConfigLaunchParams(
        saved: SavedAgentConfig,
        inputs: ConfigLaunchInputs,
        socketParams: [String: Any]
    ) -> Result<[String: Any], ConfigLaunchParamsError> {
        var launchParams = agentLaunchParams(for: saved, prompt: inputs.prompt)
        switch inputs.placement {
        case .newWorkspace: launchParams["new_workspace"] = true
        case .pane(let p):
            launchParams["pane_id"] = p
            // An area in a background workspace stays in that workspace.
            if let w = (socketParams["workspace_id"] as? String ?? socketParams["workspace"] as? String)?.nonEmpty {
                launchParams["workspace_id"] = w
            }
        case .workspace(let w): launchParams["workspace_id"] = w
        case .defaultPlacement: break
        }
        if let split = (socketParams["split"] as? String)?.nonEmpty { launchParams["split"] = split }
        if let cwd = inputs.cwd { launchParams["cwd"] = cwd }
        // C11H-138: a config saved with a machine launches there, unless the
        // caller named one. A new workspace stays on this Mac (agent.launch
        // refuses --on with --new-workspace).
        if let on = socketParams["on"] as? String, !on.isEmpty {
            launchParams["on"] = on
        } else if let machine = saved.machine, machine != SavedAgentConfig.localMachine {
            guard inputs.placement != .newWorkspace else {
                return .failure(.remoteNewWorkspace(configName: saved.name, machine: machine))
            }
            launchParams["on"] = machine
        }
        launchParams["source"] = AgentLaunchSource.socket.rawValue
        if socketParams["focus"] != nil { launchParams["focus"] = socketParams["focus"]! }
        if let window = socketParams["window_id"] { launchParams["window_id"] = window }
        launchParams = applyingConfigLaunchLineage(launchParams, from: socketParams)
        return .success(launchParams)
    }

    /// Copy the calling panel, delegation and title onto `agent.launch` params.
    /// `v2AgentLaunch` reads `caller_surface_id` (the wire spelling of
    /// `caller_panel_id`) and records that panel as the parent, whichever
    /// workspace the child opens in. A non-bool delegation value is forwarded
    /// so the existing boolean check still rejects it.
    nonisolated static func applyingConfigLaunchLineage(
        _ launchParams: [String: Any],
        from socketParams: [String: Any]
    ) -> [String: Any] {
        var out = launchParams
        if let rawCaller = socketParams["caller_surface_id"], !(rawCaller is String) {
            out["caller_surface_id"] = rawCaller
        } else if let raw = (socketParams["caller_surface_id"] as? String) ?? (socketParams["caller_panel_id"] as? String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                out["caller_surface_id"] = trimmed
            }
        }
        let delegatedRaw = socketParams["delegated"]
        let suppressedRaw = socketParams["suppressed"]
        let delegatedBad = delegatedRaw != nil && !(delegatedRaw is Bool)
        let suppressedBad = suppressedRaw != nil && !(suppressedRaw is Bool)
        if delegatedBad || suppressedBad {
            if let delegatedRaw { out["delegated"] = delegatedRaw }
            if let suppressedRaw { out["suppressed"] = suppressedRaw }
        } else if delegatedRaw != nil || suppressedRaw != nil {
            let delegated = (delegatedRaw as? Bool) ?? false
            let suppressed = (suppressedRaw as? Bool) ?? false
            if delegatedRaw != nil && suppressedRaw != nil && delegated != suppressed {
                out["delegated"] = delegated
                out["suppressed"] = suppressed
            } else if delegated || suppressed {
                out["delegated"] = true
                out["suppressed"] = true
            }
        }
        if let title = socketParams["title"] as? String {
            out["title"] = title
        }
        return out
    }

    /// The `agent.launch` params a saved config's recipe maps to (harness,
    /// model, effort, system prompt, command, env, prompt, config id), through
    /// the one tested mapping (`buildLaunchRequest`). Placement, cwd, machine
    /// and source are the caller's.
    nonisolated static func agentLaunchParams(for saved: SavedAgentConfig, prompt: String?) -> [String: Any] {
        let request = ConfigCommandCore.buildLaunchRequest(from: saved, promptOverride: prompt)
        var launchParams: [String: Any] = ["type": request.kind]
        if let m = request.model?.nonEmpty { launchParams["model"] = m }
        if let e = request.effort?.nonEmpty { launchParams["effort"] = e }
        if let sp = request.systemPrompt {
            launchParams["system_prompt_mode"] = sp.mode.rawValue
            launchParams["system_prompt"] = sp.text
        }
        if let command = request.commandOverride?.nonEmpty { launchParams["command_override"] = command }
        if !request.extraEnv.isEmpty { launchParams["env"] = request.extraEnv }
        if let prompt = request.prompt { launchParams["prompt"] = prompt }
        launchParams["config_id"] = saved.id
        return launchParams
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
            env: env,
            machine: params["machine"] as? String
        )
    }

    nonisolated static func intParam(_ params: [String: Any], _ key: String) -> Int? {
        if let i = params[key] as? Int { return i }
        if let n = params[key] as? NSNumber { return n.intValue }
        if let s = params[key] as? String { return Int(s) }
        return nil
    }
}

struct ConfigLaunchParamsError: Error, Equatable {
    let code: String
    let message: String

    static func remoteNewWorkspace(configName: String, machine: String) -> ConfigLaunchParamsError {
        ConfigLaunchParamsError(
            code: "invalid_params",
            message: "config '\(configName)' runs on \(machine), and --new-workspace opens only on this Mac; launch it without --new-workspace, or save it with --machine ask"
        )
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
