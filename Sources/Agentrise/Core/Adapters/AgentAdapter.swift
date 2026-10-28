// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit

/// What an agent can tell Agentrise beyond the basics; the UI degrades for what is missing.
package struct AgentCapabilities: OptionSet {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }
    package static let contractors = AgentCapabilities(rawValue: 1 << 0)
    package static let webSearch = AgentCapabilities(rawValue: 1 << 1)
    package static let registry = AgentCapabilities(rawValue: 1 << 2)
}

/// Gives one agent's hook events their meaning.
protocol AgentAdapter {
    static var capabilities: AgentCapabilities { get }
    static func translate(_ e: SlimEvent) -> TowerEvent
}

enum Adapters {
    /// nil is Claude Code, and what hook binaries from before `agent` existed send.
    static func adapter(for agent: AgentKind?) -> any AgentAdapter.Type {
        switch agent {
        case nil, .claude?: return ClaudeAdapter.self
        case .codex?: return CodexAdapter.self
        }
    }
}

extension Session {
    package var capabilities: AgentCapabilities { Adapters.adapter(for: agent).capabilities }
}

extension TowerStore {
    package mutating func apply(_ e: SlimEvent, context: SessionContext) -> [TowerEffect] {
        let effects = apply(Adapters.adapter(for: e.agent).translate(e), context: context)
        if let pid = e.agentPid { noteAgentPid(e.sessionId, pid) }
        return effects
    }
}
