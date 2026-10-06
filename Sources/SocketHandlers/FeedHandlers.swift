import Foundation

private struct FeedAnswerPrepared {
    let resolved: TerminalController.TabSendPhaseAResolved
    let terminalSurface: TerminalSurface
    let nativeSurface: ghostty_surface_t
    let surfaceLifetimeID: UUID
    let identity: FeedAnswerIdentity
    let projectedRow: FeedAnswerProjectionRow
    let operatorInputAt: Date?
}

/// The feed methods name their panel by `panel_id`. C11-337: `tab_id` and
/// `surface_id` are legacy spellings, accepted forever; `panel_id` wins.
enum FeedPanelParam {
    static let keys = ["panel_id", "tab_id", "surface_id"]

    /// The first panel key the caller set, or `panel_id` when none is.
    static func key(in params: [String: Any]) -> String {
        keys.first { params[$0] != nil } ?? keys[0]
    }

    static func rawValue(in params: [String: Any]) -> String? {
        params[key(in: params)] as? String
    }
}

private enum FeedAnswerPreparation {
    case ready(FeedAnswerPrepared)
    case error(TerminalController.V2CallResult)
}

private enum FeedAnswerDeliveryStart {
    case started(FailClosedCommitGate<FeedAnswerSubmitOutcome>, [String: Any])
    case error(TerminalController.V2CallResult)
}

extension TerminalController {
    // Worker-only. Parses off main and does not move focus.
    nonisolated func v2FeedList(params: [String: Any]) -> V2CallResult {
        guard CapabilityFeatures.current.supports(.feedAsks) else {
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
        let raw = (params["scope"] as? String) ?? FeedScope.attention.rawValue
        guard let scope = FeedScope(rawValue: raw) else {
            return .err(code: "invalid_params", message: "invalid_params", data: nil)
        }
        return .ok(FeedProjectionBridge.shared.list(scope: scope))
    }

    // Worker-only. A failed note never changes the journal append receipt.
    nonisolated func v2FeedNoteDisplay(params: [String: Any]) -> V2CallResult {
        guard CapabilityFeatures.current.supports(.feedAsks) else {
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
        guard let workspaceRaw = params["workspace_id"] as? String, let workspaceID = UUID(uuidString: workspaceRaw),
              let tabRaw = FeedPanelParam.rawValue(in: params), let tabID = UUID(uuidString: tabRaw),
              let eventRaw = params["event_id"] as? String, let eventID = UUID(uuidString: eventRaw),
              let agentKind = params["agent_kind"] as? String, !agentKind.isEmpty,
              let sessionID = params["session_id"] as? String, !sessionID.isEmpty else {
            return .err(code: FeedNoteError.unmatched.rawValue, message: FeedNoteError.unmatched.rawValue, data: nil)
        }
        let requestID = params["request_id"] as? String
        let prompt = params["prompt"] as? String
        let options = params["options"] as? [String]
        if params["options"] != nil && options == nil {
            return .err(code: "invalid_params", message: "invalid_params", data: nil)
        }
        guard let owner = JournalCoordinator.shared.exactOwner(tabID: tabID),
              owner.agentKind == agentKind, owner.sessionID == sessionID, owner.tabID == tabID,
              JournalCoordinator.shared.target(tabID: tabID) == workspaceID else {
            return .err(code: FeedNoteError.unmatched.rawValue, message: FeedNoteError.unmatched.rawValue, data: nil)
        }
        if let code = FeedProjectionBridge.shared.acceptNote(
            tabID: tabID,
            workspaceID: workspaceID,
            agentKind: agentKind,
            sessionID: sessionID,
            eventID: eventID,
            requestID: requestID,
            prompt: prompt,
            options: options
        ) {
            return .err(code: code, message: code, data: nil)
        }
        return .ok(["accepted": true])
    }

    /// Focus intent. Validates both UUIDs before selection. `selectWorkspace` does not activate
    /// the app; `focusWorkspace` does, so this path does not call it.
    func v2FeedOpen(params: [String: Any]) -> V2CallResult {
        guard CapabilityFeatures.current.supports(.feedAsks) else {
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
        guard let workspaceID = v2UUID(params, "workspace_id"),
              let tabID = v2UUID(params, FeedPanelParam.key(in: params)) else {
            return .err(code: "invalid_params", message: "invalid_params", data: nil)
        }
        return v2MainSync {
            guard AppDelegate.shared?.selectFeedTarget(.init(workspaceID: workspaceID, tabID: tabID)) == true else {
                return .err(code: "unavailable", message: "unavailable", data: nil)
            }
            return .ok([
                "workspace_id": workspaceID.uuidString,
                "panel_id": tabID.uuidString,
                "tab_id": tabID.uuidString,
            ])
        }
    }

    /// Worker-only guarded prose submission. It never selects or focuses the
    /// target; the only focus path is the documented empty-text `feed.open` fallback.
    nonisolated func v2FeedAnswer(params: [String: Any]) -> V2CallResult {
        guard CapabilityFeatures.current.supports(.feedAsks) else {
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
        guard let workspaceRaw = params["workspace_id"] as? String,
              let workspaceID = UUID(uuidString: workspaceRaw),
              let tabRaw = FeedPanelParam.rawValue(in: params),
              let tabID = UUID(uuidString: tabRaw),
              let text = params["text"] as? String else {
            return .err(code: "invalid_params", message: "feed.answer requires workspace_id, panel_id, and text", data: nil)
        }
        if let refusalCode = FeedAnswerTextPolicy.refusalCode(for: text) {
            var data = feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
            data["nothing_was_sent"] = true
            data["guidance"] = "c11 feed open"
            return .err(
                code: refusalCode,
                message: String(
                    localized: "feed.answer.multilineUnsupported",
                    defaultValue: "Multiline feed answers are unsupported in c11 1.0. Nothing was sent; use c11 feed open to answer in the tab."
                ),
                data: data
            )
        }
        guard text.utf8.count <= 16 * 1024 else {
            return feedAnswerError(
                code: "answer_too_long",
                data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
            )
        }
        guard Self.socketTextIsPasteDeliverable(text) else {
            return feedAnswerError(
                code: "not_prose",
                data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
            )
        }
        let actorRaw = params["by"] as? String ?? TabAttentionActor.agent.rawValue
        guard let actor = TabAttentionActor(rawValue: actorRaw) else {
            return .err(code: "invalid_params", message: "by must be agent or operator", data: nil)
        }

        let body = Self.trimmingTrailingNewlines(text)
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v2FeedAnswerOpen(workspaceID: workspaceID, tabID: tabID)
        }
        guard FeedAnswerInFlight.begin(tabID: tabID) else {
            return feedAnswerError(
                code: "submit_pending",
                data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
            )
        }
        defer { FeedAnswerInFlight.end(tabID: tabID) }

        let phaseASema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var preparation: FeedAnswerPreparation = .error(
            .err(code: "internal_error", message: "feed.answer preparation failed", data: nil)
        )
        Task { @MainActor in
            defer { phaseASema.signal() }
            preparation = prepareFeedAnswer(workspaceID: workspaceID, tabID: tabID)
        }
        phaseASema.wait()
        let prepared: FeedAnswerPrepared
        switch preparation {
        case .ready(let value): prepared = value
        case .error(let error): return error
        }

        let phaseBSema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var deliveryStart: FeedAnswerDeliveryStart = .error(
            .err(code: "internal_error", message: "feed.answer delivery could not start", data: nil)
        )
        Task { @MainActor in
            defer { phaseBSema.signal() }
            deliveryStart = beginFeedAnswerDelivery(prepared, body: body, answer: text, actor: actor)
        }
        phaseBSema.wait()

        let gate: FailClosedCommitGate<FeedAnswerSubmitOutcome>
        let inputFields: [String: Any]
        switch deliveryStart {
        case .started(let value, let fields):
            gate = value
            inputFields = fields
        case .error(let error):
            return error
        }

        guard let outcome = gate.wait(timeout: 1.0) else {
            var data = prepared.resolved.responseEnvelope
            for (key, value) in inputFields { data[key] = value }
            for (key, value) in feedAnswerStatusFields(delivered: true, submitted: false, retry: "unsafe") {
                data[key] = value
            }
            return feedAnswerError(code: "submit_unconfirmed", data: data)
        }

        var data = prepared.resolved.responseEnvelope
        for (key, value) in inputFields { data[key] = value }
        switch outcome {
        case .targetLost, .pastedNotSubmitted, .submitUnconfirmed:
            guard let failure = FeedAnswerFailureDisposition.make(for: outcome) else {
                return feedAnswerError(code: "internal_error", data: data)
            }
            for (key, value) in feedAnswerStatusFields(delivered: true, submitted: false, retry: failure.retry) {
                data[key] = value
            }
            return feedAnswerError(code: failure.code, data: data)
        case .submitted(let flagLowered, let flagEpoch):
            for (key, value) in feedAnswerStatusFields(delivered: true, submitted: true, retry: "unsafe") {
                data[key] = value
            }
            data["answered"] = prepared.identity.startKind == .turnEnd || flagLowered
            data["flag_lowered"] = flagLowered
            if let flagEpoch { data["flag_epoch"] = flagEpoch }
            return .ok(data)
        }
    }

    private nonisolated func v2FeedAnswerOpen(workspaceID: UUID, tabID: UUID) -> V2CallResult {
        let semaphore = DispatchSemaphore(value: 0)
        let context = SocketCommandContext.current
        nonisolated(unsafe) var result: V2CallResult = .err(
            code: "internal_error", message: "feed.open did not return", data: nil
        )
        nonisolated(unsafe) var blockedTarget: UUID?
        Task { @MainActor in
            SocketCommandContext.withContext(context) {
                result = withSocketCommandPolicy(commandKey: "feed.open", isV2: true) {
                    defer { blockedTarget = SocketCommandContext.current?.blockedTarget }
                    return v2FeedOpen(params: [
                        "workspace_id": workspaceID.uuidString,
                        "panel_id": tabID.uuidString,
                    ])
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let blockedTarget {
            return .err(
                code: "workspace_switch_blocked",
                message: SocketCommandContext.blockedMessage,
                data: ["target": blockedTarget.uuidString]
            )
        }
        switch result {
        case .ok(let value):
            guard var payload = value as? [String: Any] else {
                return .err(code: "internal_error", message: "feed.open returned an invalid result", data: nil)
            }
            payload["opened"] = true
            payload["delivered"] = false
            payload["queued"] = false
            payload["submitted"] = false
            payload["answered"] = false
            payload["retry"] = "safe"
            return .ok(payload)
        case .err(let code, let message, let data):
            if code == "unavailable" { return .err(code: code, message: message, data: data) }
            return .err(code: code, message: message, data: data)
        }
    }

    @MainActor
    private func prepareFeedAnswer(
        workspaceID: UUID,
        tabID: UUID
    ) -> FeedAnswerPreparation {
        switch resolveSurfaceSendTargets(params: [
            "workspace_id": workspaceID.uuidString,
            "surface_id": tabID.uuidString,
        ]) {
        case .err(let error):
            if case .err(let code, _, _) = error, code == "not_ready" { return .error(error) }
            return .error(feedAnswerError(
                code: "unavailable",
                data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
            ))
        case .ok(let resolved):
            guard resolved.workspaceId == workspaceID,
                  resolved.tabId == tabID,
                  resolved.workspace.panels[tabID] != nil else {
                return .error(feedAnswerError(
                    code: "unavailable",
                    data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
                ))
            }
            let terminalSurface = resolved.terminalPanel.surface
            guard let nativeSurface = terminalSurface.surface else {
                return .error(feedAnswerError(
                    code: "not_ready",
                    data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
                ))
            }
            guard !terminalSurface.isInputTransactionActive else {
                return .error(feedAnswerError(
                    code: "submit_pending",
                    data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
                ))
            }
            let owner = JournalCoordinator.shared.exactOwner(tabID: tabID)
            let snapshot = JournalCoordinator.shared.snapshot(tabID: tabID)
            let attention = TabMetadataStore.shared.attentionSnapshot(workspaceId: workspaceID, surfaceId: tabID)
            guard let projectedRow = FeedProjectionBridge.shared.answerRow(tabID: tabID),
                  let identity = FeedAnswerEligibility.capture(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    targetWorkspaceID: JournalCoordinator.shared.target(tabID: tabID),
                    owner: owner,
                    snapshot: snapshot,
                    attention: attention,
                    projectedRow: projectedRow
                  ) else {
                return .error(feedAnswerError(
                    code: "ineligible",
                    data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
                ))
            }
            guard let region = capturePromptInputRegion(surface: nativeSurface) else {
                return .error(feedAnswerInputRefusal(.unavailable, data: feedAnswerStatusFields(
                    delivered: false, submitted: false, retry: "safe"
                )))
            }
            let observation = PromptInputObservation.activeScreen(region)
            guard case .deliver(.checked) = SendInputGuard.decide(
                state: observation.classification.state,
                allowUnguarded: false
            ) else {
                return .error(feedAnswerInputRefusal(
                    observation.classification.state,
                    data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe"),
                    observation: observation
                ))
            }
            return .ready(FeedAnswerPrepared(
                resolved: resolved,
                terminalSurface: terminalSurface,
                nativeSurface: nativeSurface,
                surfaceLifetimeID: terminalSurface.nativeSurfaceLifetimeID,
                identity: identity,
                projectedRow: projectedRow,
                operatorInputAt: terminalSurface.lastOperatorInputAt
            ))
        }
    }

    @MainActor
    private func beginFeedAnswerDelivery(
        _ prepared: FeedAnswerPrepared,
        body: String,
        answer: String,
        actor: TabAttentionActor
    ) -> FeedAnswerDeliveryStart {
        guard feedAnswerTargetIsCurrent(prepared) else {
            return .error(feedAnswerError(
                code: "unavailable",
                data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
            ))
        }
        guard !prepared.terminalSurface.isInputTransactionActive else {
            return .error(feedAnswerError(
                code: "submit_pending",
                data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
            ))
        }
        guard FeedProjectionBridge.shared.answerRow(tabID: prepared.identity.tabID) == prepared.projectedRow else {
            return .error(feedAnswerError(
                code: "ineligible",
                data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
            ))
        }
        guard feedAnswerRowIsCurrent(prepared) else {
            return .error(feedAnswerError(
                code: "ineligible",
                data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
            ))
        }
        guard prepared.terminalSurface.lastOperatorInputAt == prepared.operatorInputAt else {
            return .error(feedAnswerInputRefusal(
                .draft,
                data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe")
            ))
        }
        guard let region = capturePromptInputRegion(surface: prepared.nativeSurface) else {
            return .error(feedAnswerInputRefusal(.unavailable, data: feedAnswerStatusFields(
                delivered: false, submitted: false, retry: "safe"
            )))
        }
        let observation = PromptInputObservation.activeScreen(region)
        guard case .deliver(.checked) = SendInputGuard.decide(
            state: observation.classification.state,
            allowUnguarded: false
        ) else {
            return .error(feedAnswerInputRefusal(
                observation.classification.state,
                data: feedAnswerStatusFields(delivered: false, submitted: false, retry: "safe"),
                observation: observation
            ))
        }

        let gate = FailClosedCommitGate<FeedAnswerSubmitOutcome> { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return .targetLost }
                return self.completeFeedAnswer(
                    prepared,
                    body: body,
                    answer: answer,
                    actor: actor
                )
            }
        }
        _ = deliverSocketSendText(
            body,
            submit: true,
            preserveNewlines: true,
            terminalSurface: prepared.terminalSurface,
            surface: prepared.nativeSurface,
            feedAnswerGate: gate
        )
        return .started(gate, observation.responseFields)
    }

    @MainActor
    private func completeFeedAnswer(
        _ prepared: FeedAnswerPrepared,
        body: String,
        answer: String,
        actor: TabAttentionActor
    ) -> FeedAnswerSubmitOutcome {
        let targetIsCurrent = feedAnswerTargetIsCurrent(prepared)
        let rowIsCurrent = targetIsCurrent && feedAnswerRowIsCurrent(prepared)
        let operatorInputUnchanged = prepared.terminalSurface.lastOperatorInputAt == prepared.operatorInputAt
        if let outcome = FeedAnswerPreReturnCheck.outcome(
            targetIsCurrent: targetIsCurrent,
            rowIsCurrent: rowIsCurrent,
            operatorInputUnchanged: operatorInputUnchanged,
            composer: nil
        ) {
            return outcome
        }
        guard let region = capturePromptInputRegion(surface: prepared.nativeSurface) else {
            return .pastedNotSubmitted
        }
        let inputState = PromptInputClassifier.classify(region).state
        let composer = inputState == .draft ? PromptInputClassifier.composerText(region) : nil
        if let outcome = FeedAnswerPreReturnCheck.outcome(
            targetIsCurrent: targetIsCurrent,
            rowIsCurrent: rowIsCurrent,
            operatorInputUnchanged: operatorInputUnchanged,
            composer: FeedAnswerComposerCheck.compare(state: inputState, composer: composer, expected: body)
        ) {
            return outcome
        }

        prepared.terminalSurface.armFeedAnswerFlagLowerSuppression()
        let handedOff = prepared.terminalSurface.sendKeyNow(.returnKey, captureNativeHandoff: true)
        prepared.terminalSurface.clearFeedAnswerFlagLowerSuppression()
        return FeedAnswerHandoff.outcome(
            nativeHandoff: handedOff,
            startKind: prepared.identity.startKind
        ) {
            guard let expectedEpoch = prepared.identity.flagEpoch else { return .unavailable }
            do {
                let result = try TabAttentionService.shared.lower(
                    workspaceId: prepared.identity.workspaceID,
                    surfaceId: prepared.identity.tabID,
                    by: actor,
                    answer: answer,
                    expectedFlagEpoch: expectedEpoch
                )
                return result.applied[MetadataKey.flag] == true ? .lowered : .replaced
            } catch {
                return .unavailable
            }
        }
    }

    @MainActor
    private func feedAnswerTargetIsCurrent(_ prepared: FeedAnswerPrepared) -> Bool {
        let resolved = prepared.resolved
        guard resolved.workspaceManager.workspaces.contains(where: { $0 === resolved.workspace }),
              resolved.workspace.terminalPanel(for: prepared.identity.tabID) === resolved.terminalPanel,
              resolved.terminalPanel.surface === prepared.terminalSurface,
              prepared.terminalSurface.id == prepared.identity.tabID,
              prepared.terminalSurface.workspaceId == prepared.identity.workspaceID,
              prepared.terminalSurface.nativeSurfaceLifetimeID == prepared.surfaceLifetimeID,
              prepared.terminalSurface.surface == prepared.nativeSurface else { return false }
        return true
    }

    @MainActor
    private func feedAnswerRowIsCurrent(_ prepared: FeedAnswerPrepared) -> Bool {
        let identity = prepared.identity
        guard FeedProjectionBridge.shared.answerRow(tabID: identity.tabID) == prepared.projectedRow else {
            return false
        }
        let owner = JournalCoordinator.shared.exactOwner(tabID: identity.tabID)
        let snapshot = JournalCoordinator.shared.snapshot(tabID: identity.tabID)
        let attention = TabMetadataStore.shared.attentionSnapshot(
            workspaceId: identity.workspaceID,
            surfaceId: identity.tabID
        )
        return FeedAnswerEligibility.stillEligible(
            identity,
            targetWorkspaceID: JournalCoordinator.shared.target(tabID: identity.tabID),
            owner: owner,
            snapshot: snapshot,
            attention: attention
        )
    }

    private nonisolated func feedAnswerInputRefusal(
        _ state: PromptInputState,
        data: [String: Any],
        observation: PromptInputObservation? = nil
    ) -> V2CallResult {
        var fields = data
        for (key, value) in observation?.responseFields ?? PromptInputClassification(
            state: state, draftLength: nil
        ).responseFields(source: nil, observedAtMs: nil) {
            fields[key] = value
        }
        fields["input_guard"] = SendInputGuardStatus.refused.rawValue
        let reason: String
        switch SendInputGuard.decide(state: state, allowUnguarded: false) {
        case .refuse(let value): reason = value
        case .deliver(.unknown): reason = state.rawValue
        case .deliver(.checked), .deliver(.overridden), .deliver(.refused): reason = state.rawValue
        case .unavailable: reason = PromptInputState.unavailable.rawValue
        }
        fields["reason"] = reason
        return .err(
            code: "input_guard_refused",
            message: String(format: String(
                localized: "socket.send.guard_refused",
                defaultValue: "Input guard refused the send because a %@ is present. Nothing was sent; do not press Enter. If the operator is mid-draft, raise a flag (c11 raise-flag) instead of retrying."
            ), reason),
            data: fields
        )
    }

    private nonisolated func feedAnswerStatusFields(
        delivered: Bool,
        submitted: Bool,
        retry: String
    ) -> [String: Any] {
        [
            "delivered": delivered,
            "queued": false,
            "submitted": submitted,
            "answered": false,
            "retry": retry,
        ]
    }

    private nonisolated func feedAnswerError(code: String, data: [String: Any]) -> V2CallResult {
        .err(code: code, message: code, data: data)
    }
}
