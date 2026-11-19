import Combine
import Foundation
import os
import Bonsplit

// C11H-261: the waiting check's reader, Jev client and judge. The contract
// (settings, key store, verdict, health) is in WaitingCheck.swift.

// MARK: - Screen reading (pure)

/// Reads the foot of a coding agent's terminal (the active area, the bottom of
/// the terminal): finds the harness's idle composer, the agent's latest
/// message, and applies the `Needs you:` convention.
enum WaitingCheckScreen {
    static let withheldPlaceholder = "[line withheld by c11]"
    /// Harnesses whose message markers this reader knows. Every other agent
    /// is read by Jev alone.
    static let conventionHarnesses: Set<String> = ["claude-code", "codex"]
    /// What may follow `Needs you:` for the reply to read as done.
    static let nothingPhrases: Set<String> = ["nothing", "none", "nothing yet", "nothing for now", "n/a"]

    /// Status glyphs Claude Code puts in front of its spinner and turn summary.
    private static let statusGlyphs: Set<Character> = ["✻", "✽", "✶", "✳", "✢", "·", "*"]
    /// Lines from the bottom searched for the composer and for a live turn.
    private static let footLines = 20

    /// The screen without the harness's composer and blank tail, and whether
    /// an idle composer was found: Claude Code's `─` rule pair around the `❯`
    /// prompt, or Codex's `›` composer (never a numbered `› 1.` choice).
    struct Foot: Equatable {
        let lines: [String]
        let composerFound: Bool
    }

    // MARK: Strip

    static func foot(lines: [String]) -> Foot {
        var out = lines.map { $0.replacingOccurrences(of: "\r", with: "") }
        trimBlankTail(&out)
        guard let cut = composerStart(in: out) else { return Foot(lines: out, composerFound: false) }
        out = Array(out[..<cut])
        trimBlankTail(&out)
        return Foot(lines: out, composerFound: true)
    }

    static func strip(lines: [String]) -> [String] {
        foot(lines: lines).lines
    }

    static func hasIdleComposer(lines: [String]) -> Bool {
        foot(lines: lines).composerFound
    }

    private static func composerStart(in lines: [String]) -> Int? {
        guard !lines.isEmpty else { return nil }
        let lowest = max(0, lines.count - footLines)
        var index = lines.count - 1
        while index >= lowest {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("❯"), !isChoiceLine(trimmed),
               index > 0, isRule(lines[index - 1]),
               lines[(index + 1)...].prefix(6).contains(where: isRule) {
                // Claude Code: rule, `❯` prompt (maybe several input lines), rule.
                return index - 1
            }
            if trimmed.hasPrefix("›"), !isChoiceLine(trimmed), index >= lines.count - 8 {
                // Codex: the composer and its footer sit at the very bottom.
                var above = index - 1
                while above >= 0, isBlank(lines[above]) || isRule(lines[above]) { above -= 1 }
                return above + 1
            }
            index -= 1
        }
        return nil
    }

    // MARK: Latest message

    /// The agent's latest message: from the last line starting (column 0)
    /// with `⏺ ` (Claude) or `• ` (Codex) to the end of the stripped screen,
    /// without the turn summary (`✻ Cooked for 2m 5s`) or blank tail. Nil when
    /// there is no marker, or when a user prompt's echo or an interruption
    /// follows the last marker (the agent has not answered since).
    static func latestMessage(lines: [String]) -> [String]? {
        latestBlock(lines: lines)?.lines
    }

    /// The latest message and whether its marker line is on screen. The judge
    /// reads only the visible area (bounded, cheap), so a reply taller than a
    /// short panel has its marker scrolled off: then every visible line above
    /// the idle composer is the tail of that last block, since any newer block
    /// would start with its own marker. Callers gate this on the harness
    /// (Claude Code, Codex) and on the idle composer.
    struct LatestBlock: Equatable {
        let lines: [String]
        let hasMarker: Bool
    }

    static func latestBlock(lines: [String]) -> LatestBlock? {
        let stripped = strip(lines: lines)
        let start = stripped.lastIndex(where: isMessageStart)
        var message = Array(stripped[(start ?? stripped.startIndex)...])
        let afterStart = start == nil ? message[...] : message.dropFirst()
        if afterStart.contains(where: { isPromptEcho($0) || isInterruption($0) }) { return nil }
        while let last = message.last, isBlank(last) || isStatusLine(last) {
            message.removeLast()
        }
        while let first = message.first, isBlank(first) { message.removeFirst() }
        guard !message.isEmpty else { return nil }
        return LatestBlock(lines: message, hasMarker: start != nil)
    }

    private static func isMessageStart(_ line: String) -> Bool {
        line.hasPrefix("⏺ ") || line == "⏺" || line.hasPrefix("• ")
    }

    /// The history echo of the operator's prompt: `> ` / `❯ ` (Claude) or
    /// `› ` (Codex) at column 0.
    private static func isPromptEcho(_ line: String) -> Bool {
        line.hasPrefix("> ") || line == ">" || line.hasPrefix("❯ ") || line.hasPrefix("› ")
    }

    /// Claude's `⎿  Interrupted · What should Claude do instead?`, Codex's
    /// `■ Conversation interrupted`.
    private static func isInterruption(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("⎿") || trimmed.hasPrefix("■") else { return false }
        return trimmed.range(of: "interrupted", options: .caseInsensitive) != nil
    }

    // MARK: Convention

    /// The `Needs you:` line in the latest message (the last one there, at
    /// the message's own indent). Done only when what follows is exactly
    /// `nothing`, `none`, `nothing yet`, `nothing for now` or `n/a`, and then
    /// nil (undecided) when a later line ends in `?`, when a numbered item
    /// follows a Needs line that does not open the message, or when the next
    /// line is not blank (a wrapped continuation; a numbered list right under
    /// an opening Needs line is allowed). A remainder that starts with
    /// `nothing`, `none`, `no` or `n/a` and says more ("nothing, unless...")
    /// is nil too, for Jev to read. Anything else reads as waiting. Nil
    /// without such a line, or without a latest message.
    static func convention(lines: [String]) -> (outcome: WaitingCheckVerdict.Outcome, quote: String)? {
        guard let block = latestBlock(lines: lines) else { return nil }
        let message = block.lines
        // The skill's report opens with the Needs line (on the marker line or
        // the first line after it), then may list its changes as numbered items.
        // Without the marker on screen nothing is known to open the message.
        let firstBodyLine = message.indices.dropFirst().first { !isBlank(message[$0]) }
        for offset in message.indices.reversed() {
            let isMarkerLine = block.hasMarker && offset == message.startIndex
            guard let rest = needsYouRemainder(message[offset], isFirstLine: isMarkerLine) else {
                continue
            }
            let quote = quoteText(message[offset])
            guard isNothing(rest) else {
                // C11H-276: "nothing, unless you want another run" is not
                // plainly nothing and not plainly an ask: Jev reads it.
                return startsWithNothingWord(rest) ? nil : (.waiting, quote)
            }
            let opensMessage = block.hasMarker && (offset == message.startIndex || offset == firstBodyLine)
            let after = message[(offset + 1)...]
            // A question anywhere after it leaves the reply undecided.
            if after.contains(where: isQuestion) { return nil }
            // A numbered item after a closing Needs line is a list of asks.
            if !opensMessage, after.contains(where: isNumberedItem) { return nil }
            // After an opening Needs line only the first numbered run is the
            // list of changes; a later run (under a heading) may be asks.
            if opensMessage, Self.numberedRuns(in: after) > 1 { return nil }
            // A non-blank line right after it may continue it ("nothing
            // except approving..."), unless it opens the list of changes.
            if let next = after.first, !isBlank(next), !(opensMessage && isNumberedItem(next)) { return nil }
            return (.done, quote)
        }
        return nil
    }

    /// Separate runs of numbered items: a run ends at a non-blank line that is
    /// neither a numbered item nor indented under one.
    static func numberedRuns(in lines: ArraySlice<String>) -> Int {
        var runs = 0
        var inRun = false
        for line in lines where !isBlank(line) {
            if isNumberedItem(line) {
                if !inRun { runs += 1; inRun = true }
            } else if inRun, line.prefix(while: { $0 == " " }).count > 3 {
                continue
            } else {
                inRun = false
            }
        }
        return runs
    }

    private static let needsYouPattern = try! NSRegularExpression(
        pattern: #"^needs you\**\s*:\s*(.*)$"#, options: [.caseInsensitive])
    private static let numberedItemPattern = try! NSRegularExpression(
        pattern: #"^\s*\d+[.)]\s"#, options: [])

    /// What follows `Needs you:`, or nil when the line is not one written at
    /// the message's own indent: the marker line itself, or a line indented
    /// at most two spaces, optionally a `-`/`*`/`•` bullet and markdown bold.
    /// Never inside a `│`/`>` quote, a `⎿` tool-output block or a box.
    static func needsYouRemainder(_ line: String, isFirstLine: Bool) -> String? {
        var text = Substring(line)
        if isFirstLine {
            guard text.hasPrefix("⏺ ") || text.hasPrefix("• ") else { return nil }
            text = text.dropFirst(2)
        } else {
            let indent = text.prefix(while: { $0 == " " }).count
            guard indent <= 2 else { return nil }
            text = text.dropFirst(indent)
        }
        for bullet in ["- ", "* ", "• "] where text.hasPrefix(bullet) {
            text = text.dropFirst(bullet.count)
            break
        }
        text = text.drop(while: { $0 == "*" || $0 == "_" })
        let normalized = String(text).trimmingCharacters(in: .whitespaces)
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = needsYouPattern.firstMatch(in: normalized, range: range),
              let restRange = Range(match.range(at: 1), in: normalized) else { return nil }
        return String(normalized[restRange])
    }

    /// True when the remainder is one of `nothingPhrases`, ignoring markdown,
    /// case and a trailing `.` or `!`.
    static func isNothing(_ remainder: String) -> Bool {
        var text = remainder.filter { $0 != "*" && $0 != "_" && $0 != "`" }
            .trimmingCharacters(in: .whitespaces)
        while let last = text.last, last == "." || last == "!" || last == " " { text.removeLast() }
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return nothingPhrases.contains(words)
    }

    /// Words that open a remainder Jev should read rather than one that asks.
    static let nothingWords: Set<String> = ["nothing", "none", "no", "n/a"]

    /// True when the remainder's first word, ignoring markdown and case, is
    /// one of `nothingWords` ("nothing, unless...", "no blockers; ..."). Whole
    /// words only: `now`, `nope` and `not` are not.
    static func startsWithNothingWord(_ remainder: String) -> Bool {
        let text = remainder.filter { $0 != "*" && $0 != "_" && $0 != "`" }
            .trimmingCharacters(in: .whitespaces).lowercased()
        let word = text.prefix { $0.isLetter || $0 == "/" }
        return nothingWords.contains(String(word))
    }

    private static func isQuestion(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_`\"'”’)"))
            .hasSuffix("?")
    }

    private static func isNumberedItem(_ line: String) -> Bool {
        numberedItemPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func quoteText(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("⏺ ") || text.hasPrefix("• ") { text = String(text.dropFirst(2)) }
        return text
    }

    // MARK: Busy and open prompts

    private static let busyPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"esc to interrupt"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"^\s*[✻✽✶✳✢·*]\s+\S+…"#, options: []),
        try! NSRegularExpression(pattern: #"Running \d+ shell command"#, options: []),
        try! NSRegularExpression(pattern: #"Thinking…"#, options: []),
        try! NSRegularExpression(pattern: #"Waiting for API response"#, options: [.caseInsensitive]),
    ]

    /// True when the foot of the screen shows a live turn: `esc to interrupt`,
    /// a spinner (`✻ Reticulating… (15s`), `⏺ Running 1 shell command`,
    /// `Thinking…`, `Waiting for API response`. A finished turn's summary
    /// (`✻ Cooked for 2m 5s · done 11:36 AM`) is not busy.
    static func isBusy(lines: [String]) -> Bool {
        var foot = lines
        trimBlankTail(&foot)
        for line in foot.suffix(footLines) {
            let range = NSRange(line.startIndex..., in: line)
            if busyPatterns.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                return true
            }
        }
        return false
    }

    /// True when a permission or choice prompt is open at the foot: a
    /// numbered choice (`❯ 1. Yes`, Codex's `› 1. Yes, proceed`), `Do you want
    /// to`, `Would you like to`. Such a screen is never judged.
    static func hasOpenChoicePrompt(lines: [String]) -> Bool {
        for line in strip(lines: lines).suffix(15) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("❯") || trimmed.hasPrefix("›"), isChoiceLine(trimmed) { return true }
            if trimmed.range(of: "Do you want to", options: .caseInsensitive) != nil { return true }
            if trimmed.range(of: "Would you like to", options: .caseInsensitive) != nil { return true }
        }
        return false
    }

    // MARK: Jev payload

    /// The stripped screen with withheld lines replaced, clipped to its last
    /// `maxCharacters`. A line is withheld when it contains a term, and both
    /// lines of an adjacent pair are withheld when the term spans them.
    static func preparedScreen(lines: [String], withheldTerms: [String], maxCharacters: Int) -> String {
        let terms = withheldTerms.filter { !$0.isEmpty }
        let stripped = strip(lines: lines)
        var withheld = Set<Int>()
        if !terms.isEmpty {
            for (index, line) in stripped.enumerated() where containsTerm(line, terms) {
                withheld.insert(index)
            }
            for index in stripped.indices.dropLast() {
                let head = stripped[index].trimmingCharacters(in: .whitespaces)
                let tail = stripped[index + 1].trimmingCharacters(in: .whitespaces)
                if containsTerm(head + tail, terms) || containsTerm(head + " " + tail, terms) {
                    withheld.insert(index)
                    withheld.insert(index + 1)
                }
            }
        }
        let text = stripped.enumerated()
            .map { withheld.contains($0.offset) ? withheldPlaceholder : $0.element }
            .joined(separator: "\n")
        guard text.count > maxCharacters else { return text }
        return String(text.suffix(maxCharacters))
    }

    /// The panel title, or the placeholder when it contains a withheld term.
    static func preparedTitle(_ title: String, withheldTerms: [String]) -> String {
        containsTerm(title, withheldTerms.filter { !$0.isEmpty }) ? withheldPlaceholder : title
    }

    private static func containsTerm(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// The last non-empty line of the latest message, trimmed and clipped.
    static func lastMessageLine(lines: [String], maxCharacters: Int = 200) -> String? {
        guard let line = latestMessage(lines: lines)?.last(where: { !isBlank($0) }) else { return nil }
        let trimmed = quoteText(line)
        return trimmed.count > maxCharacters ? String(trimmed.prefix(maxCharacters)) : trimmed
    }

    // MARK: Helpers

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 8 && trimmed.allSatisfy { $0 == "─" || $0 == "━" }
    }

    /// `❯ 1. Yes`, `› 2. No`: a choice in a permission or selection prompt.
    private static func isChoiceLine(_ trimmed: String) -> Bool {
        let rest = trimmed.drop(while: { $0 == "❯" || $0 == "›" || $0 == " " })
        let digits = rest.prefix(while: \.isNumber)
        return !digits.isEmpty && rest.dropFirst(digits.count).first == "."
    }

    /// `✻ Cooked for 2m 5s`: a glyph, a space, then text.
    private static func isStatusLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, statusGlyphs.contains(first) else { return false }
        return trimmed.dropFirst().first == " "
    }

    private static func trimBlankTail(_ lines: inout [String]) {
        while let last = lines.last, isBlank(last) { lines.removeLast() }
    }
}

// MARK: - Jev client

struct JevHTTPResponse {
    let status: Int
    let body: Data
}

struct JevAnswer: Equatable {
    let model: String?
    /// Probability the agent needs a reply from a human.
    let needsHuman: Double
    let stopKind: String
    let stopKindConfidence: Double?
}

enum JevError: Error, Equatable {
    case auth(status: Int)
    case http(status: Int)
    case timeout
    case network(code: Int)
    case malformed

    /// Network, timeout and 5xx are retried once.
    var isTransient: Bool {
        switch self {
        case .timeout, .network: return true
        case .http(let status): return status >= 500
        case .auth, .malformed: return false
        }
    }

    /// A short class for logs and `fleet --json`; never the key or the screen.
    var errorClass: String {
        switch self {
        case .auth(let status): return "auth_\(status)"
        case .http(let status): return "http_\(status)"
        case .timeout: return "timeout"
        case .network(let code): return "network_\(code)"
        case .malformed: return "malformed"
        }
    }
}

/// TypeSafe System One, model `jev-latest`, asked two client-defined
/// questions about a settled agent screen.
struct JevClient {
    typealias Transport = (_ request: URLRequest,
                           _ completion: @escaping (Result<JevHTTPResponse, Error>) -> Void) -> Void

    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"
    static let timeout: TimeInterval = 10
    static let maxScreenCharacters = 3500
    static let needsHumanThreshold = 0.25
    static let doneStopKinds: Set<String> = ["done", "offering", "stopped_with_work_left", "waiting_on_agent"]

    let key: String
    var transport: Transport = JevClient.urlSessionTransport
    var retryDelay: TimeInterval = 1
    var retryQueue: DispatchQueue = .global(qos: .utility)

    static let questions: [String: Any] = [
        "needs_human": [
            "type": "noul",
            "instructions": "Does the agent need a reply from a human before it can make further progress? Answer yes if its latest message asks a question, requests a decision, or asks for permission or a go-ahead, or if a permission or choice prompt is open. Answer no if it reported completion and asked nothing beyond an optional offer, if it is working, or if it waits on another agent, job or timer. A closing line such as `Needs you: nothing` means no, whatever the message offers after it. The agent narrating its own next step (what it will do, click or check) is not an ask.",
        ] as [String: Any],
        "stop_kind": [
            "type": "choice",
            "instructions": "`screen` is the end of a coding agent's terminal, read just after its turn ended. Judged from the agent's most recent message, where did it stop? Reading, inspecting or planning earlier in the screen does not decide this; the latest message does.",
            "criteria": [
                "asks_human": "Its latest message asks the human a question, a decision, a go-ahead or a permission it needs before it can go on, or a permission or choice prompt is open on the screen.",
                "offering": "It finished, needs nothing from the human, and ends with an optional offer ('Want me to...?', 'I can also...') or an optional step the human may take.",
                "done": "It reported its work finished (a fix landed, a review or report written, a task finished), and asks and offers nothing.",
                "stopped_with_work_left": "It paused, parked or was told to stop with work it named still undone, and needs nothing from the human now. 'Needs you: nothing' with work left for later is this.",
                "waiting_on_agent": "Its latest message says it waits on another agent, a review, a merge, a job, a timer or a background process (work 'in flight', 'waiting for'), and asks the human nothing.",
                "error_state": "It stopped on an error, a crash, a usage limit, a lost connection or an interrupted or cancelled turn.",
                "not_stopped": "The screen shows it still mid-turn (a running tool call, a spinner, 'Working'), or shows no agent at all.",
            ] as [String: Any],
        ] as [String: Any],
    ]

    static func makeRequest(key: String, panelTitle: String, harness: String, screen: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "state": [
                "panel_title": panelTitle,
                "harness": harness,
                "screen": screen,
            ] as [String: Any],
            "model": model,
            "questions": questions,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    /// One judgment, retried once after `retryDelay` on a transient failure.
    /// The completion runs on the transport's (or retry queue's) thread.
    func judge(panelTitle: String, harness: String, screen: String,
               completion: @escaping (Result<JevAnswer, JevError>) -> Void) {
        let request = Self.makeRequest(key: key, panelTitle: panelTitle, harness: harness, screen: screen)
        attempt(request, retriesLeft: 1, completion: completion)
    }

    private func attempt(_ request: URLRequest, retriesLeft: Int,
                         completion: @escaping (Result<JevAnswer, JevError>) -> Void) {
        transport(request) { result in
            let outcome: Result<JevAnswer, JevError>
            switch result {
            case .success(let response): outcome = Self.parse(status: response.status, body: response.body)
            case .failure(let error): outcome = .failure(Self.classify(error))
            }
            if case .failure(let error) = outcome, error.isTransient, retriesLeft > 0 {
                let retry = { self.attempt(request, retriesLeft: retriesLeft - 1, completion: completion) }
                if retryDelay <= 0 {
                    retry()
                } else {
                    retryQueue.asyncAfter(deadline: .now() + retryDelay, execute: retry)
                }
                return
            }
            completion(outcome)
        }
    }

    static func parse(status: Int, body: Data) -> Result<JevAnswer, JevError> {
        if status == 401 || status == 403 { return .failure(.auth(status: status)) }
        guard (200..<300).contains(status) else { return .failure(.http(status: status)) }
        guard let object = (try? JSONSerialization.jsonObject(with: body, options: [])) as? [String: Any],
              let answers = object["answers"] as? [String: Any],
              let needsHuman = answers["needs_human"] as? [String: Any],
              let noul = (needsHuman["noul"] as? NSNumber)?.doubleValue,
              let stopKind = answers["stop_kind"] as? [String: Any],
              let choice = stopKind["choice"] as? String else {
            return .failure(.malformed)
        }
        return .success(JevAnswer(
            model: object["model"] as? String,
            needsHuman: noul,
            stopKind: choice,
            stopKindConfidence: (stopKind["confidence"] as? NSNumber)?.doubleValue
        ))
    }

    static func classify(_ error: Error) -> JevError {
        if let jev = error as? JevError { return jev }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timeout : .network(code: urlError.code.rawValue)
        }
        return .network(code: (error as NSError).code)
    }

    /// `done` when the agent needs no human (needs_human < 0.25) and stopped
    /// finished, offering, parked, or waiting on other work; else `waiting`.
    static func outcome(for answer: JevAnswer) -> WaitingCheckVerdict.Outcome {
        answer.needsHuman < needsHumanThreshold && doneStopKinds.contains(answer.stopKind) ? .done : .waiting
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 2
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    static let urlSessionTransport: Transport = { request, completion in
        JevClient.session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(.success(JevHTTPResponse(status: status, body: data ?? Data())))
        }.resume()
    }
}

// MARK: - Judge

/// The two toggles the judge acts on, compared on every defaults change.
private struct WaitingCheckToggles: Equatable {
    let enabled: Bool
    let jevEnabled: Bool

    static func current() -> WaitingCheckToggles {
        WaitingCheckToggles(enabled: WaitingCheckSettings.isEnabled(), jevEnabled: WaitingCheckSettings.isJevEnabled())
    }
}

/// Judges each agent turn-end notification once. Main-thread object; its
/// verdict table is lock-guarded and readable from any thread.
@MainActor
final class WaitingCheckJudge: ObservableObject {
    static let shared = WaitingCheckJudge()

    @Published private(set) var jevHealth: WaitingCheckJevHealth
    /// Bumped on every recorded verdict, for views that show verdicts.
    @Published private(set) var verdictRevision = 0

    /// Seconds after the notification before the first screen read.
    static let firstReadDelay: TimeInterval = 1.0
    static let readInterval: TimeInterval = 1.0
    /// Settling stops here; a screen that never read the same twice is not judged.
    static let settleCap: TimeInterval = 12.0
    static let maxConcurrentJevCalls = 4

    private static let logger = Logger(subsystem: "com.stage11.c11", category: "waiting_check")

    private struct Job {
        let notificationID: UUID
        let workspaceID: UUID
        let panelID: UUID
        /// When this judgment started (a re-judge starts a fresh settle).
        let startedAt: Date
        var lastScreen: [String]?
    }

    private struct JevRequest {
        let notificationID: UUID
        let workspaceID: UUID
        let panelID: UUID
        let startedAt: Date
        let panelTitle: String
        let harness: String
        let screen: String
        let quote: String?
    }

    private var jobs: [UUID: Job] = [:]
    private var jevQueue: [JevRequest] = []
    /// Notifications with a Jev call on the wire.
    private var jevInFlight = Set<UUID>()
    /// Set by a 401/403: no Jev call until the key changes.
    private var authFailedAt: Date?
    /// Bumped on every key change; an auth failure from an older key is ignored.
    private var keyGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var attentionCancellables: [AnyCancellable] = []
    private var lastToggles: WaitingCheckToggles

    // Lock-guarded, any thread.
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var verdicts: [UUID: WaitingCheckVerdict] = [:]
    private nonisolated(unsafe) static var latestNotificationByPanel: [UUID: UUID] = [:]
    private nonisolated(unsafe) static var observedToggles: WaitingCheckToggles?

    private init() {
        let toggles = WaitingCheckToggles.current()
        lastToggles = toggles
        jevHealth = Self.health(jevEnabled: toggles.jevEnabled, hasKey: JevKeyStore.read() != nil)
        Self.lock.lock(); Self.observedToggles = toggles; Self.lock.unlock()
        let center = NotificationCenter.default
        // queue: nil runs on the posting thread and never waits for main; the
        // handler compares two bools and hops to main only on a change.
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { _ in
            let next = WaitingCheckToggles.current()
            WaitingCheckJudge.lock.lock()
            let changed = WaitingCheckJudge.observedToggles != next
            WaitingCheckJudge.observedToggles = next
            WaitingCheckJudge.lock.unlock()
            guard changed else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WaitingCheckJudge.shared.togglesChanged() }
            }
        })
        observers.append(center.addObserver(
            forName: .waitingCheckConfigurationDidChange, object: nil, queue: nil
        ) { _ in
            let next = WaitingCheckToggles.current()
            WaitingCheckJudge.lock.lock(); WaitingCheckJudge.observedToggles = next; WaitingCheckJudge.lock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WaitingCheckJudge.shared.togglesChanged() }
            }
        })
        observers.append(center.addObserver(forName: .jevKeyDidChange, object: nil, queue: nil) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WaitingCheckJudge.shared.jevKeyChanged() }
            }
        })
        // A flag, ask, error or show that arrives with no notification (a
        // bypass-mode ask on the journal route) ends a done verdict.
        attentionCancellables.append(FeedProjectionBridge.shared.snapshots
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { WaitingCheckJudge.shared.dropDoneVerdictsUnderAttention() } })
        attentionCancellables.append(PanelAttentionIndex.shared.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { WaitingCheckJudge.shared.dropDoneVerdictsUnderAttention() } })
    }

    // MARK: Verdict table (any thread)

    nonisolated static func verdict(forNotificationID id: UUID) -> WaitingCheckVerdict? {
        lock.lock(); defer { lock.unlock() }
        return verdicts[id]
    }

    /// True when the notification was judged done and the check is on.
    nonisolated static func isDone(_ notificationID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let verdict = verdicts[notificationID], verdict.outcome == .done else { return false }
        return observedToggles?.enabled ?? WaitingCheckSettings.isEnabled()
    }

    /// The verdict on the panel's most recently judged notification.
    nonisolated static func latestVerdict(panelID: UUID) -> WaitingCheckVerdict? {
        lock.lock(); defer { lock.unlock() }
        guard let id = latestNotificationByPanel[panelID] else { return nil }
        return verdicts[id]
    }

    /// The operator marked these unread again, or attention came up on their
    /// panels: no verdict hides them. Returns whether any verdict was dropped.
    @discardableResult
    nonisolated static func dropVerdicts(forNotificationIDs ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        let before = verdicts.count
        for id in ids { verdicts.removeValue(forKey: id) }
        latestNotificationByPanel = latestNotificationByPanel.filter { !ids.contains($0.value) }
        return verdicts.count != before
    }

    /// Notifications the operator marked unread. Never judged again, so a
    /// settle or Jev call in flight, or a later re-judge, cannot hide them.
    private nonisolated(unsafe) static var operatorUnread = Set<UUID>()

    /// The operator marked these unread: drop their verdicts and never judge
    /// them again. `live` prunes ids whose notification is gone. Returns
    /// whether any verdict was dropped.
    @discardableResult
    nonisolated static func operatorMarkedUnread(_ ids: Set<UUID>, live: Set<UUID>) -> Bool {
        lock.lock()
        operatorUnread = operatorUnread.union(ids).intersection(live)
        lock.unlock()
        return dropVerdicts(forNotificationIDs: ids)
    }

    nonisolated static func isOperatorUnread(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return operatorUnread.contains(id)
    }

    nonisolated static func doneVerdicts() -> [WaitingCheckVerdict] {
        lock.lock(); defer { lock.unlock() }
        return verdicts.values.filter { $0.outcome == .done }
    }

    /// The done verdicts whose panel now has deterministic attention.
    nonisolated static func doneVerdictsUnderAttention(
        _ done: [WaitingCheckVerdict], attentionPanels: Set<UUID>
    ) -> Set<UUID> {
        Set(done.lazy.filter { attentionPanels.contains($0.panelID) }.map(\.notificationID))
    }

    /// Main: drops done verdicts on panels that are flagged or carry a feed
    /// ask, error or show, then refreshes what counts as waiting.
    private func dropDoneVerdictsUnderAttention() {
        let done = Self.doneVerdicts()
        guard !done.isEmpty else { return }
        var panels = Set(FeedProjectionBridge.shared.snapshot().attentionRows.map(\.panelID))
        for snapshot in PanelAttentionIndex.shared.snapshots.values where snapshot.isFlagged {
            panels.insert(snapshot.surfaceId)
        }
        let drop = Self.doneVerdictsUnderAttention(done, attentionPanels: panels)
        guard Self.dropVerdicts(forNotificationIDs: drop) else { return }
        verdictRevision &+= 1
        TerminalNotificationStore.shared.refreshSignalEligibility()
    }

    private nonisolated static func store(_ verdict: WaitingCheckVerdict, liveNotificationIDs: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        verdicts = verdicts.filter { liveNotificationIDs.contains($0.key) }
        verdicts[verdict.notificationID] = verdict
        latestNotificationByPanel = latestNotificationByPanel.filter { verdicts[$0.value] != nil }
        latestNotificationByPanel[verdict.panelID] = verdict.notificationID
    }

#if DEBUG
    nonisolated static func recordForTesting(_ verdict: WaitingCheckVerdict) {
        lock.lock(); defer { lock.unlock() }
        verdicts[verdict.notificationID] = verdict
        latestNotificationByPanel[verdict.panelID] = verdict.notificationID
    }

    nonisolated static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        verdicts = [:]
        latestNotificationByPanel = [:]
        operatorUnread = []
    }
#endif

    // MARK: Health and configuration

    private static func health(jevEnabled: Bool, hasKey: Bool) -> WaitingCheckJevHealth {
        guard jevEnabled else { return .off }
        return hasKey ? .live : .noKey
    }

    private var isJevUsable: Bool {
        WaitingCheckSettings.isJevEnabled() && JevKeyStore.read() != nil && authFailedAt == nil
    }

    /// A toggle changed: refresh eligibility; re-judge only when the master
    /// switch or the Jev switch just turned on. Jev's failure is kept.
    private func togglesChanged() {
        let toggles = WaitingCheckToggles.current()
        let turnedOn = (toggles.enabled && !lastToggles.enabled) || (toggles.jevEnabled && !lastToggles.jevEnabled)
        lastToggles = toggles
        let base = Self.health(jevEnabled: toggles.jevEnabled, hasKey: JevKeyStore.read() != nil)
        if let authFailedAt, base == .live {
            jevHealth = .failing(since: authFailedAt, reason: "auth")
        } else if base != .live {
            jevHealth = base
        } else if case .failing = jevHealth {
            // Stays failing until a call succeeds or the key changes.
        } else {
            jevHealth = .live
        }
        if !toggles.enabled {
            jobs.removeAll()
            jevQueue.removeAll()
        }
        TerminalNotificationStore.shared.refreshSignalEligibility()
        if toggles.enabled, turnedOn { judgeUnjudgedUnread() }
    }

    /// The key was saved or cleared: the only reset of Jev's health and of an
    /// auth failure, and a re-judge with the new key.
    private func jevKeyChanged() {
        keyGeneration += 1
        authFailedAt = nil
        jevHealth = Self.health(jevEnabled: WaitingCheckSettings.isJevEnabled(), hasKey: JevKeyStore.read() != nil)
        if WaitingCheckSettings.isEnabled(), isJevUsable { judgeUnjudgedUnread() }
    }

    private func isInFlight(_ notificationID: UUID) -> Bool {
        jevInFlight.contains(notificationID)
            || jobs.values.contains { $0.notificationID == notificationID }
            || jevQueue.contains { $0.notificationID == notificationID }
    }

    private func judgeUnjudgedUnread() {
        for notification in TerminalNotificationStore.shared.notifications
        where !notification.isRead && notification.origin == .turnEnd
            && Self.verdict(forNotificationID: notification.id) == nil {
            turnEndNotificationAdded(notification)
        }
    }

    // MARK: Trigger

    /// Called on main by the notification store for every added notification.
    /// Only an agent's own turn end (`origin == .turnEnd`) is judged.
    func turnEndNotificationAdded(_ notification: TerminalNotification) {
        guard WaitingCheckSettings.isEnabled(), notification.origin == .turnEnd,
              let panelID = notification.surfaceId, !isInFlight(notification.id),
              !Self.isOperatorUnread(notification.id) else { return }
        guard agentKind(workspaceID: notification.workspaceId, panelID: panelID) != nil,
              !hasDeterministicAttention(workspaceID: notification.workspaceId, panelID: panelID) else { return }
        jobs[panelID] = Job(notificationID: notification.id, workspaceID: notification.workspaceId,
                            panelID: panelID, startedAt: Date(), lastScreen: nil)
        schedule(panelID: panelID, notificationID: notification.id, after: Self.firstReadDelay)
    }

    private func schedule(panelID: UUID, notificationID: UUID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                WaitingCheckJudge.shared.step(panelID: panelID, notificationID: notificationID)
            }
        }
    }

    /// One read per second until two consecutive reads match. At the cap
    /// without a match nothing is judged.
    private func step(panelID: UUID, notificationID: UUID) {
        guard var job = jobs[panelID], job.notificationID == notificationID else { return }
        guard WaitingCheckSettings.isEnabled(), isCurrentUnread(notificationID, panelID: panelID) else {
            jobs.removeValue(forKey: panelID)
            return
        }
        let capped = Date().timeIntervalSince(job.startedAt) >= Self.settleCap
        let screen = readScreen(workspaceID: job.workspaceID, panelID: panelID)
        if let screen, screen == job.lastScreen {
            jobs.removeValue(forKey: panelID)
            judge(job, screen: screen)
            return
        }
        if capped {
            jobs.removeValue(forKey: panelID)
            log(job, source: nil, outcome: "unsettled", error: nil)
            return
        }
        // A busy or failed read leaves the last good one to compare against.
        if let screen { job.lastScreen = screen }
        jobs[panelID] = job
        schedule(panelID: panelID, notificationID: notificationID, after: Self.readInterval)
    }

    // MARK: Judging

    private func judge(_ job: Job, screen: [String]) {
        guard let kind = agentKind(workspaceID: job.workspaceID, panelID: job.panelID) else { return }
        if WaitingCheckScreen.isBusy(lines: screen) {
            log(job, source: nil, outcome: "skipped_busy", error: nil)
            return
        }
        if WaitingCheckScreen.hasOpenChoicePrompt(lines: screen) {
            log(job, source: nil, outcome: "skipped_prompt", error: nil)
            return
        }
        // Done needs the idle composer at the foot; without it nothing is judged.
        guard WaitingCheckScreen.hasIdleComposer(lines: screen) else {
            log(job, source: nil, outcome: "no_composer", error: nil)
            return
        }
        if WaitingCheckScreen.conventionHarnesses.contains(kind),
           let convention = WaitingCheckScreen.convention(lines: screen) {
            let recorded = record(WaitingCheckVerdict(
                notificationID: job.notificationID, workspaceID: job.workspaceID, panelID: job.panelID,
                outcome: convention.outcome, source: .convention, needsHuman: nil, stopKind: nil,
                quote: convention.quote, judgedAt: Date()))
            log(job, source: .convention, outcome: recorded ? convention.outcome.rawValue : "stale", error: nil)
            return
        }
        guard isJevUsable else {
            log(job, source: nil, outcome: "no_convention", error: nil)
            return
        }
        let terms = WaitingCheckSettings.withheldTerms()
        let title = AppDelegate.shared?
            .workspaceContainingPanel(panelId: job.panelID, preferredWorkspaceId: job.workspaceID)?
            .workspace.panelTitle(panelId: job.panelID) ?? ""
        jevQueue.append(JevRequest(
            notificationID: job.notificationID, workspaceID: job.workspaceID, panelID: job.panelID,
            startedAt: job.startedAt,
            panelTitle: WaitingCheckScreen.preparedTitle(title, withheldTerms: terms),
            harness: kind,
            screen: WaitingCheckScreen.preparedScreen(
                lines: screen, withheldTerms: terms, maxCharacters: JevClient.maxScreenCharacters),
            quote: WaitingCheckScreen.lastMessageLine(lines: screen)))
        startJevCalls()
    }

    private func startJevCalls() {
        while jevInFlight.count < Self.maxConcurrentJevCalls, !jevQueue.isEmpty {
            let request = jevQueue.removeFirst()
            guard isCurrentUnread(request.notificationID, panelID: request.panelID) else { continue }
            guard isJevUsable, let key = JevKeyStore.read() else {
                jevQueue.removeAll()
                return
            }
            jevInFlight.insert(request.notificationID)
            let started = Date()
            let generation = keyGeneration
            JevClient(key: key).judge(
                panelTitle: request.panelTitle, harness: request.harness, screen: request.screen
            ) { result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        WaitingCheckJudge.shared.jevFinished(
                            request, result: result, startedAt: started, keyGeneration: generation)
                    }
                }
            }
        }
    }

    /// `keyGeneration` is the key generation the call was made with.
    private func jevFinished(_ request: JevRequest, result: Result<JevAnswer, JevError>, startedAt: Date,
                             keyGeneration callGeneration: Int) {
        jevInFlight.remove(request.notificationID)
        let jevMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let job = Job(notificationID: request.notificationID, workspaceID: request.workspaceID,
                      panelID: request.panelID, startedAt: request.startedAt, lastScreen: nil)
        switch result {
        case .success(let answer):
            if WaitingCheckSettings.isJevEnabled(), JevKeyStore.read() != nil, authFailedAt == nil {
                jevHealth = .live
            }
            let outcome = JevClient.outcome(for: answer)
            let recorded = record(WaitingCheckVerdict(
                notificationID: request.notificationID, workspaceID: request.workspaceID,
                panelID: request.panelID, outcome: outcome, source: .jev,
                needsHuman: answer.needsHuman, stopKind: answer.stopKind,
                quote: request.quote, judgedAt: Date()))
            log(job, source: .jev, outcome: recorded ? outcome.rawValue : "stale", error: nil, jevMs: jevMs)
        case .failure(let error):
            if case .auth = error, callGeneration != keyGeneration {
                // A key that has since been replaced; the new one is untried.
            } else if case .auth = error {
                // No further calls until the key changes.
                let since = authFailedAt ?? Date()
                authFailedAt = since
                jevQueue.removeAll()
                jevHealth = .failing(since: since, reason: "auth")
            } else if case .failing(let since, _) = jevHealth {
                jevHealth = .failing(since: since, reason: error.errorClass)
            } else {
                jevHealth = .failing(since: Date(), reason: error.errorClass)
            }
            log(job, source: .jev, outcome: "failed", error: error.errorClass, jevMs: jevMs)
        }
        startJevCalls()
    }

    /// Records the verdict only if the check is on, the notification is
    /// still the panel's current unread one, and no flag, ask, error or show
    /// has come up since. Returns whether it was recorded.
    @discardableResult
    private func record(_ verdict: WaitingCheckVerdict) -> Bool {
        guard WaitingCheckSettings.isEnabled(),
              !Self.isOperatorUnread(verdict.notificationID),
              isCurrentUnread(verdict.notificationID, panelID: verdict.panelID),
              !hasDeterministicAttention(workspaceID: verdict.workspaceID, panelID: verdict.panelID) else {
            return false
        }
        let store = TerminalNotificationStore.shared
        Self.store(verdict, liveNotificationIDs: Set(store.notifications.map(\.id)))
        verdictRevision &+= 1
        store.refreshSignalEligibility()
        return true
    }

    // MARK: Main-thread lookups

    /// The panel's agent kind (`claude-code`, `codex`, ...), or nil when it is
    /// not an agent terminal.
    private func agentKind(workspaceID: UUID, panelID: UUID) -> String? {
        guard let found = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelID, preferredWorkspaceId: workspaceID),
              found.workspace.terminalPanel(for: panelID) != nil else { return nil }
        let kind = found.workspace.surfaceActivityTerminalKind(panelId: panelID)
        guard AreaSizePolicy.isAgentKind(kind), let kind else { return nil }
        return kind
    }

    /// A flag, an open feed ask, an error or a show: deterministic waiting.
    private func hasDeterministicAttention(workspaceID: UUID, panelID: UUID) -> Bool {
        if PanelAttentionIndex.shared.snapshot(workspaceId: workspaceID, surfaceId: panelID).isFlagged {
            return true
        }
        return FeedProjectionBridge.shared.snapshot().attentionRows.contains { $0.panelID == panelID }
    }

    /// Unread, and the newest notification for its panel (none replaced it).
    private func isCurrentUnread(_ notificationID: UUID, panelID: UUID) -> Bool {
        guard let current = TerminalNotificationStore.shared.notifications.first(where: { $0.surfaceId == panelID })
        else { return false }
        return current.id == notificationID && !current.isRead
    }

    /// One non-blocking read of the active area (`try_read_text`), the bottom
    /// of the terminal wherever the operator has scrolled. A busy renderer
    /// returns nil and the caller tries again next second.
    private func readScreen(workspaceID: UUID, panelID: UUID) -> [String]? {
        guard let found = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelID, preferredWorkspaceId: workspaceID),
              let terminal = found.workspace.terminalPanel(for: panelID),
              let surface = terminal.surface.surface,
              case .success(let bytes) = TerminalController.shared.captureTerminalReadBytes(
                surface: surface, includeScrollback: false, isAbandoned: { false },
                regions: [GHOSTTY_POINT_ACTIVE]),
              let active = bytes.active else { return nil }
        return String(decoding: active, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    // MARK: Log

    /// One line per judgment: panel, source, outcome, latency, error class.
    /// Never screen text or the key.
    private func log(_ job: Job, source: WaitingCheckVerdict.Source?, outcome: String,
                     error: String?, jevMs: Int? = nil) {
        let latencyMs = Int(Date().timeIntervalSince(job.startedAt) * 1000)
        let line = "waitingCheck.judged panel=\(job.panelID.uuidString) source=\(source?.rawValue ?? "none")"
            + " outcome=\(outcome) latency_ms=\(latencyMs)"
            + (jevMs.map { " jev_ms=\($0)" } ?? "")
            + " error=\(error ?? "none")"
        Self.logger.info("\(line, privacy: .public)")
#if DEBUG
        dlog(line)
#endif
    }
}
