import Foundation

/// Close and clear-history wording for hc terminals (C11H-24, Settled 10, A13).
/// Closing an hc terminal ends its session and everything it started; the
/// confirmation says so. Exec/fallback panels keep the plain close copy,
/// because their nohup jobs survive the hangup and this copy would be untrue.
enum HCCloseCopy {
    static var panelTitle: String {
        String(localized: "hc.close.panel.title", defaultValue: "End session?")
    }

    static var panelMessage: String {
        String(
            localized: "hc.close.panel.message",
            defaultValue: "Closing this panel ends its terminal session and every process it started, including background and nohup jobs."
        )
    }

    static var panelConfirmLabel: String {
        String(localized: "hc.close.panel.confirm", defaultValue: "End Session")
    }

    /// Appended to an area, workspace or window close message when any of its
    /// panels is an hc terminal.
    static var groupSuffix: String {
        String(
            localized: "hc.close.group.message",
            defaultValue: "This ends every terminal session in it and every process they started, including background and nohup jobs."
        )
    }

    static var groupConfirmLabel: String {
        String(localized: "hc.close.group.confirm", defaultValue: "End Sessions")
    }

    static func groupMessage(_ base: String, endsSession: Bool) -> String {
        guard endsSession else { return base }
        return base.isEmpty ? groupSuffix : base + "\n\n" + groupSuffix
    }

    /// C11H-309: appended to a several-panel close (Close Others, Close to the
    /// Left or Right) when it ends `sessionCount` hc sessions, naming how many.
    static func batchSuffix(sessionCount: Int) -> String {
        sessionCount == 1
            ? String(
                localized: "hc.close.batch.message.one",
                defaultValue: "This ends 1 terminal session and every process it started, including background and nohup jobs."
            )
            : String(
                format: String(
                    localized: "hc.close.batch.message.other",
                    defaultValue: "This ends %lld terminal sessions and every process they started, including background and nohup jobs."
                ),
                sessionCount
            )
    }

    /// The batch card's confirm button: End Session or End Sessions when any
    /// session ends, else nil for the plain Close.
    static func batchConfirmLabel(sessionCount: Int) -> String? {
        switch sessionCount {
        case 0: return nil
        case 1: return panelConfirmLabel
        default: return groupConfirmLabel
        }
    }

    static func batchMessage(_ base: String, sessionCount: Int) -> String {
        guard sessionCount > 0 else { return base }
        return base + "\n\n" + batchSuffix(sessionCount: sessionCount)
    }

    /// The line the CLI prints after a panel's handle for its end outcome.
    static func endOutcomeMessage(_ outcome: HCPanelEndOutcome) -> String {
        switch outcome {
        case .ended:
            return String(
                localized: "hc.close.outcome.ended",
                defaultValue: "Ended session: every process it started, including background and nohup jobs."
            )
        case .alreadyEnded:
            return String(localized: "hc.close.outcome.alreadyEnded", defaultValue: "Session had already ended.")
        case .kept(let holder?):
            // C11H-103: name the other panel, so the operator can find it.
            return String(format: String(
                localized: "hc.close.outcome.keptBy",
                defaultValue: "Session kept: panel %1$@ (\u{201C}%2$@\u{201D}) in workspace \u{201C}%3$@\u{201D} still shows this terminal, so it was not ended."
            ), holder.panelRef ?? holder.panelID.uuidString, holder.title, holder.workspaceTitle)
        case .kept(nil):
            return String(
                localized: "hc.close.outcome.kept",
                defaultValue: "Session kept: another panel still shows this terminal, so it was not ended."
            )
        case .none:
            return String(localized: "hc.close.outcome.none", defaultValue: "No hc session to end.")
        case .pending:
            return String(
                localized: "hc.close.outcome.pending",
                defaultValue: "End pending: hc has not yet confirmed the session's processes ended. c11 keeps the request and finishes it when hc answers."
            )
        }
    }

    /// Clear-history on an hc terminal clears this view only (X.4: the pin has
    /// no primitive to clear hc's own history).
    static var clearHistoryNotDurable: String {
        String(
            localized: "hc.clearHistory.notDurable",
            defaultValue: "Cleared this view only. hc keeps this terminal's history, so it returns after c11 restarts or reconnects."
        )
    }
}
