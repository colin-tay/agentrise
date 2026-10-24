import Foundation
import TowerKit

/// What an agent can tell Agentrise beyond the basics; the UI degrades for what is missing.
struct AgentCapabilities: OptionSet {
    let rawValue: Int
    static let contractors = AgentCapabilities(rawValue: 1 << 0)
    static let webSearch = AgentCapabilities(rawValue: 1 << 1)
    static let registry = AgentCapabilities(rawValue: 1 << 2)
}

/// Gives one agent's hook events their meaning.
protocol AgentAdapter {
    static var capabilities: AgentCapabilities { get }
    static func translate(_ e: SlimEvent) -> TowerEvent
}

enum Adapters {
    /// nil is Claude Code, and what hook binaries from before `agent` existed send.
    /// Codex shares Claude's adapter until it gets its own.
    static func adapter(for agent: AgentKind?) -> any AgentAdapter.Type {
        switch agent {
        case nil, .claude?, .codex?: return ClaudeAdapter.self
        }
    }
}

extension TowerStore {
    mutating func apply(_ e: SlimEvent, context: SessionContext) -> [TowerEffect] {
        apply(Adapters.adapter(for: e.agent).translate(e), context: context)
    }
}
