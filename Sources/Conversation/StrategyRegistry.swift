import Foundation

/// Hardcoded enum-shaped registry of `ConversationStrategy`s. We are not
/// building a plugin system — adding a new kind is one Swift file in
/// `Sources/Conversation/Strategies/` plus an entry in `defaultStrategies`.
///
/// Stored as an immutable map keyed by `kind`; lookups are O(1).
struct ConversationStrategyRegistry: Sendable {
    private let strategies: [String: any ConversationStrategy]

    init(strategies: [any ConversationStrategy]) {
        var map: [String: any ConversationStrategy] = [:]
        for strategy in strategies {
            map[strategy.kind] = strategy
        }
        self.strategies = map
    }

    func strategy(forKind kind: String) -> (any ConversationStrategy)? {
        strategies[kind]
    }

    func contains(kind: String) -> Bool {
        strategies[kind] != nil
    }

    var allKinds: [String] {
        Array(strategies.keys).sorted()
    }

    /// Default v1 registry. Lands strategies for every built-in agent type:
    /// claude-code (push-primary), codex (pull-primary, ambiguity-aware),
    /// grok (best-effort resume), opencode/kimi/github-copilot (fresh-launch
    /// only).
    static let v1: ConversationStrategyRegistry = {
        ConversationStrategyRegistry(strategies: [
            ClaudeCodeStrategy(),
            CodexStrategy(),
            GrokStrategy(),
            OpencodeStrategy(),
            KimiStrategy(),
            GitHubCopilotStrategy(),
            PiStrategy()
        ])
    }()
}
