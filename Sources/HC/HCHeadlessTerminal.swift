import Foundation

/// C11H-112: an hc terminal that runs with no Ghostty surface (screen locked, hidden workspace, minimized).
///
/// The terminal is created and attached exactly as a surface-backed one is, but the attachment's sink discards
/// output and its grid is the default 80x24; hc keeps the screen and history, so the real surface that attaches
/// later (replacing this attachment) is sent the current screen. Input goes through the same attachment, the
/// same `HCInputCoordinator`, so `send` and `send-key` reach the terminal through hc.
enum HCHeadless {
    static let grid = HCGridSize(columns: 80, rows: 24)

    /// A panel gets its headless start after this delay unless a real surface exists first, so a panel that is
    /// about to be shown (the common case) is created once, at its real size, and never at 80x24 first.
    nonisolated(unsafe) static var graceNanoseconds: UInt64 = 300_000_000

    /// How long before a pending restored panel reports its wait. It keeps
    /// observing liveness after this diagnostic budget expires.
    nonisolated(unsafe) static var restoredLiveWaitSeconds: TimeInterval = HCLimits.creationResolutionSeconds

    /// The bytes a named key (`send-key`) types into a terminal that has no surface to encode it. Normal
    /// (not application-cursor) sequences; the vocabulary is `TerminalController.namedKeyEvent`'s. Nil for an
    /// unknown name.
    static func keyText(forNamedKey name: String) -> String? {
        let key = name.lowercased()
        let esc = "\u{1B}"
        switch key {
        case "ctrl-c", "ctrl+c", "sigint": return "\u{03}"
        case "ctrl-d", "ctrl+d", "eof": return "\u{04}"
        case "ctrl-z", "ctrl+z", "sigtstp": return "\u{1A}"
        case "ctrl-\\", "ctrl+\\", "sigquit": return "\u{1C}"
        case "enter", "return": return "\r"
        case "tab": return "\t"
        case "escape", "esc": return esc
        case "backspace", "bs": return "\u{7F}"
        case "delete", "del", "forward-delete": return esc + "[3~"
        case "space": return " "
        case "up", "arrow-up", "arrowup": return esc + "[A"
        case "down", "arrow-down", "arrowdown": return esc + "[B"
        case "right", "arrow-right", "arrowright": return esc + "[C"
        case "left", "arrow-left", "arrowleft": return esc + "[D"
        case "home": return esc + "[H"
        case "end": return esc + "[F"
        case "pageup", "page-up", "pgup": return esc + "[5~"
        case "pagedown", "page-down", "pgdn": return esc + "[6~"
        case "f1": return esc + "OP"
        case "f2": return esc + "OQ"
        case "f3": return esc + "OR"
        case "f4": return esc + "OS"
        case "f5": return esc + "[15~"
        case "f6": return esc + "[17~"
        case "f7": return esc + "[18~"
        case "f8": return esc + "[19~"
        case "f9": return esc + "[20~"
        case "f10": return esc + "[21~"
        case "f11": return esc + "[23~"
        case "f12": return esc + "[24~"
        default:
            if key.hasPrefix("ctrl-") || key.hasPrefix("ctrl+") {
                let letter = key.dropFirst(5)
                if letter.count == 1, let scalar = letter.unicodeScalars.first, scalar.value >= 97, scalar.value <= 122 {
                    return String(UnicodeScalar(scalar.value - 96)!)
                }
            }
            return nil
        }
    }

    /// Which guard a socket send to a terminal uses. With a Ghostty surface: the existing screen guard, unchanged.
    /// With none (a headless terminal): the decision from hc's terminal status below.
    enum SendRoute: Equatable {
        case screenGuard
        case statusDecision
        case notHeadless
    }

    static func sendRoute(hasSurface: Bool, hasHeadlessBridge: Bool) -> SendRoute {
        if hasSurface { return .screenGuard }
        return hasHeadlessBridge ? .statusDecision : .notHeadless
    }

    enum SendDecision: Equatable {
        case deliver
        /// `status` is a log-safe token naming why: `blocked`, `no_current_status`, `not_running`.
        case refuse(status: String)
        /// C11H-306: a mailbox doorbell is between its line and its Return in this terminal; text sent now would be
        /// submitted with that line. Busy, try again: no override lifts it.
        case busy
    }

    /// A send to a terminal with no screen, decided from hc's own record of the terminal (C11H-112, option b):
    /// an agent idle/done at its prompt delivers; a working agent delivers (Claude Code and Codex queue typed
    /// input); a plain shell delivers; an agent blocked on a dialog or auth refuses (`--allow-unguarded`
    /// overrides); an agent whose status is unknown or stale (no current record, no status yet, an error, a
    /// machine that is not connected) refuses, and the override also lifts that. A terminal that is not running
    /// is never sent to.
    static func sendDecision(record: HCTerminalRecord?, allowUnguarded: Bool, doorbellInFlight: Bool = false) -> SendDecision {
        if doorbellInFlight { return .busy }
        guard let record else { return allowUnguarded ? .deliver : .refuse(status: "no_current_status") }
        guard record.state == .running else { return .refuse(status: "not_running") }
        let current = record.machineAvailability == .local || record.machineAvailability == .connected
        let isAgent = HCRemoteMailboxForeground.agentOwnsTerminal(record) || record.status != nil
        guard isAgent else { return .deliver }                         // a plain shell: nothing to protect
        guard current else { return allowUnguarded ? .deliver : .refuse(status: "no_current_status") }
        switch record.status {
        case "idle", "done", "working": return .deliver
        case "blocked": return allowUnguarded ? .deliver : .refuse(status: "blocked")
        default: return allowUnguarded ? .deliver : .refuse(status: "no_current_status")
        }
    }

    /// C11H-298: whether a send to a terminal with no screen waits for an agent's turn after its Return: only
    /// when hc's foreground program is an agent. hc keeps a program's last OSC 7501 status until the terminal
    /// ends, so a status alone can be a stale word left by an agent that exited to a shell, an editor or a REPL.
    static func sendTargetsAgent(_ record: HCTerminalRecord?) -> Bool {
        HCRemoteMailboxForeground.agentOwnsTerminal(record)
    }

    enum Start: Equatable {
        case now
        case afterGrace
        case leave
    }

    /// Whether a panel asks for the headless start, and when.
    /// - restoring: a panel rebuilt by a session restore; its start waits for the restore gate and follows
    ///   today's restore policy (a live record reattaches; the ended/Recovered rules are the start path's own).
    static func startPolicy(persistent: Bool, hasNativeSurface: Bool, hasHeadlessAttachment: Bool,
                            restoring: Bool) -> Start {
        guard persistent, !hasNativeSurface, !hasHeadlessAttachment else { return .leave }
        return restoring ? .now : .afterGrace
    }
}

/// Whether the agent in a terminal that has no screen is at its prompt, from hc's own agent status (OSC 7501
/// `session.status`, the gate the remote doorbell uses): idle or done is at the prompt, blocked is on a question
/// or dialog, anything else (working, no status, a plain shell) is not ready yet.
enum HCAgentReadiness: Equatable {
    case ready
    case waiting
    case blocked
}

extension HCHeadless {
    static func promptReadiness(_ record: HCTerminalRecord?) -> HCAgentReadiness {
        guard let record, record.state == .running else { return .waiting }
        switch record.status {
        case "idle", "done": return .ready
        case "blocked": return .blocked
        default: return .waiting
        }
    }
}

/// Rendering for a headless terminal: no screen to read, a fixed grid, no native parse.
struct HCHeadlessRendering: HCRenderingAdapter {
    @MainActor func wrapNewTerminalArgv(_ argv: [String]) -> [String] {
        HCSizeGate.wrap(argv, panelGrid: HCHeadless.grid)
    }
    func noteRawInput(_ ptr: UnsafeRawPointer, _ len: Int) {}
    func noteOutput(_ chunk: HCOutputChunk) {}
    func didParse(_ chunk: HCOutputChunk) {}
    func claimInBandGrid(columns: UInt16, rows: UInt16) -> Bool { true }
    @MainActor func displayStateForAttach(attachmentGeneration: UInt64, focused: Bool) -> HCDisplayState? { nil }
    @MainActor func attached(_ attachment: any HCAttachment) {}
    @MainActor func detached() {}
    @MainActor func surfaceSizeChanged() {}
    @MainActor func focusChanged(_ focused: Bool) {}
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
}

/// Input for a headless terminal: the surface-free equivalent of `HCNativePasteEncoder`. Text is sent as typed
/// bytes (a newline is a carriage return, as a terminal's paste does when the program has not asked for
/// bracketed paste, which a headless terminal cannot know), and a requested Return is a separate frame.
///
/// C11H-298: the Return waits the same paste-settle delay the screen path uses. Typed bytes arrive as one burst,
/// and Claude Code and Codex take a Return inside that burst as part of the text: the line stayed in the
/// composer, unsent, while the send reported it submitted.
struct HCHeadlessInputEncoder: HCInputEncoder {
    let returnDelayNanoseconds: @Sendable (HCInputSource) -> UInt64

    init(returnDelayNanoseconds: @escaping @Sendable (HCInputSource) -> UInt64 = HCHeadlessInputEncoder.settleDelayNanoseconds) {
        self.returnDelayNanoseconds = returnDelayNanoseconds
    }

    /// The screen path's delay for each source: `TextBoxBehavior.returnKeyDelayMs`, plus the feed-answer settle
    /// for the mailbox and Feed. A Debug build reads `C11_HEADLESS_RETURN_DELAY_MS` to measure other delays.
    static func settleDelayNanoseconds(_ source: HCInputSource) -> UInt64 {
        var milliseconds = source == .feed || source == .mailbox
            ? FeedAnswerTiming.returnDelayMilliseconds(baseDelayMs: TextBoxBehavior.returnKeyDelayMs, debugHoldMs: 0)
            : max(0, TextBoxBehavior.returnKeyDelayMs)
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["C11_HEADLESS_RETURN_DELAY_MS"], let value = Int(raw), value >= 0 {
            milliseconds = value
        }
        #endif
        return UInt64(milliseconds) * 1_000_000
    }

    /// C11H-362: an operator paste or drop is refused before any byte. With no screen this encoder cannot know
    /// whether the program enabled bracketed paste, so it could never fence the paste; typing it raw would run
    /// every line it carries.
    func maximumEncodedBytes(for request: HCInputRequest) -> Int? {
        guard !request.source.isOperatorPaste, request.payload.count <= HCLimits.transactionBytes else { return nil }
        return request.payload.count * 2 + 64
    }

    static func body(_ payload: Data) -> Data {
        Data(payload.map { $0 == 0x0A ? 0x0D : $0 })
    }

    func encode(_ request: HCInputRequest) async -> Result<[HCOutboundFrame], HCInputRefusal> {
        guard maximumEncodedBytes(for: request) != nil else {
            return .failure(request.source.isOperatorPaste ? .unavailable : .tooLarge)
        }
        var frames: [HCOutboundFrame] = []
        let body = Self.body(request.payload)
        if !body.isEmpty { frames.append(.data(body)) }
        if request.submitReturn {
            // A bare Return has no burst to wait out.
            let delay = body.isEmpty ? 0 : returnDelayNanoseconds(request.source)
            frames.append(.submitReturnAfter(Data([0x0D]), delayNanoseconds: delay))
        }
        return frames.isEmpty ? .failure(.unavailable) : .success(frames)
    }
}

extension HCNativeBridge {
    /// A bridge with no Ghostty surface: output is consumed and dropped (hc re-sends the screen on the next
    /// attach), input is encoded by `HCHeadlessInputEncoder`.
    @MainActor
    static func headless(panelID: UUID, report: @escaping @Sendable (HCInputOutcome) -> Void,
                         rendering: any HCRenderingAdapter = HCHeadlessRendering(),
                         encoder: any HCInputEncoder = HCHeadlessInputEncoder()) -> HCNativeBridge {
        let bridge = HCNativeBridge(panelID: panelID, rendering: rendering, encoder: encoder, report: report)
        bridge.installProcessor(process: { _ in }, removeFromUse: {}, destroy: {})
        return bridge
    }
}
