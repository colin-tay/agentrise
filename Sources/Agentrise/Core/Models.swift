// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit

package enum Rank: String, CaseIterable {
    case seniorDirector, seniorExpert, seniorEngineer, newGrad

    package var title: String { RankBook.current.title(self) }

    /// Color of the light strip on the robot's body, as 0xRRGGBB.
    package var stripeHex: UInt32 {
        switch self {
        case .seniorDirector: return 0xFFCF3F
        case .seniorExpert: return 0xC084FF
        case .seniorEngineer: return 0x4CC3FF
        case .newGrad: return 0x6FF0A8
        }
    }

    static func from(model: String?) -> Rank { RankBook.current.rank(for: model) }
}

package enum Activity: String {
    case reading, searching, coding, runningCommand, commandFailed, browsing, planning,
         delegating, sendingLark, thinking, compacting, waitingAtDoor, waitingForSubs, reporting, resting, standby,
         sleeping, briefing, other

    package var label: String {
        switch self {
        case .reading: return "读文件"
        case .searching: return "搜索中"
        case .coding: return "写代码"
        case .runningCommand: return "跑命令"
        case .commandFailed: return "命令报错"
        case .browsing: return "查资料"
        case .planning: return "列计划"
        case .delegating: return "开会派活"
        case .sendingLark: return "发飞书"
        case .thinking: return "思考中"
        case .compacting: return "整理记忆"
        case .waitingAtDoor: return "等你回复"
        case .waitingForSubs: return "等小弟"
        case .reporting: return "汇报中"
        case .resting: return "做完了"
        case .standby: return "待命"
        case .sleeping: return "睡觉"
        case .briefing: return "听任务"
        case .other: return "干活中"
        }
    }
}

package enum Room: String, CaseIterable {
    case meeting, ceoOffice, desks, whiteboard, intel, archive, pantry, mailroom, serverRoom, sleepPods

    package var title: String {
        switch self {
        case .meeting: return "👥 会议室"
        case .ceoOffice: return "🙋 CEO 办公室"
        case .desks: return "⌨️ 工位区"
        case .whiteboard: return "📝 白板"
        case .intel: return "🌐 情报室"
        case .archive: return "📁 档案室"
        case .pantry: return "☕ 茶水间"
        case .mailroom: return "✉️ 收发室"
        case .serverRoom: return "🖥 机房"
        case .sleepPods: return "🌙 睡眠舱"
        }
    }

    /// 3 = 3F … 0 = B1
    var floor: Int {
        switch self {
        case .meeting, .ceoOffice: return 3
        case .desks, .whiteboard, .intel: return 2
        case .archive, .pantry, .mailroom, .serverRoom: return 1
        case .sleepPods: return 0
        }
    }
}

package enum ActivityMap {
    static func activity(toolName: String, command: String?) -> Activity {
        switch toolName {
        case "Read": return .reading
        case "Grep", "Glob", "LS": return .searching
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return .coding
        case "Bash", "BashOutput", "KillShell":
            if CCConnectIndex.enabled, let c = command, c.contains("cc-connect send") { return .sendingLark }
            return .runningCommand
        case "WebSearch", "WebFetch": return .browsing
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "EnterPlanMode", "ExitPlanMode": return .planning
        case "Agent", "Task": return .delegating
        default:
            if toolName.hasPrefix("mcp__Claude_Browser__") || toolName.hasPrefix("mcp__claude-in-chrome__") { return .browsing }
            return .other
        }
    }

    /// nil = stay where you are.
    package static func room(for a: Activity) -> Room? {
        switch a {
        case .reading, .searching, .compacting: return .archive
        case .coding, .other, .standby: return .desks
        case .runningCommand, .commandFailed: return .serverRoom
        case .browsing: return .intel
        case .planning: return .whiteboard
        case .delegating, .briefing, .waitingForSubs: return .meeting
        case .sendingLark: return .mailroom
        case .waitingAtDoor, .reporting: return .ceoOffice
        case .resting: return .pantry
        case .sleeping: return .sleepPods
        case .thinking: return nil
        }
    }
}

package enum SessionStatus: String {
    case working, waiting, done, error, standby, sleeping
}

package enum SessionSource: Equatable {
    case desktop(hostSessionId: String?)
    case lark
    case terminal(bundleId: String?)
}

package struct SubAgent: Equatable {
    package var id: String
    package var type: String
    package var activity: Activity
    package var startedAt: Date
}

package struct Contractor: Equatable {
    package var id: String
    package var description: String
    package var startedAt: Date
}

package struct Session: Equatable {
    package var id: String
    package var title: String
    package var source: SessionSource
    package var rank: Rank
    package var status: SessionStatus
    package var activity: Activity
    package var teamIndex: Int
    package var subs: [String: SubAgent] = [:]
    package var contractors: [String: Contractor] = [:]
    package var delivered = 0
    package var failedSubs = 0
    package var contractorsDone = 0
    package var larkSent = false
    package var waitingSummary: String?
    package var transientErrorAt: Date?
    package var statusSince: Date
    var lastActivityAt: Date
    package var cwd: String?
    var transcriptPath: String?
    package var isHidden = false
    package var modelKnown = false
    /// The model name as the agent reported it, so ranks can be recomputed after a Settings change.
    var model: String?
    package var lastSeenInRegistry: Date?
    package var agent: AgentKind = .claude
    /// The agent's own process, for agents without a session registry to tell when it is gone.
    var agentPid: Int32?

    package var isLark: Bool { source == .lark }
}

package struct TowerCounts: Equatable {
    package var working = 0, waiting = 0, done = 0, subs = 0, contractors = 0, sleeping = 0, standby = 0

    package init(working: Int = 0, waiting: Int = 0, done: Int = 0, subs: Int = 0, contractors: Int = 0, sleeping: Int = 0, standby: Int = 0) {
        self.working = working; self.waiting = waiting; self.done = done; self.subs = subs
        self.contractors = contractors; self.sleeping = sleeping; self.standby = standby
    }
}

package enum TowerEffect: Equatable {
    case statusChanged(sessionId: String, from: SessionStatus, to: SessionStatus)
    case subFinished(sessionId: String, subId: String, success: Bool)
    case contractorFinished(sessionId: String, contractorId: String)
    case sessionLeft(sessionId: String)
}

/// Team identity of a main agent: halo color + emblem glyph.
package enum Team {
    /// Halo colors as 0xRRGGBB.
    package static let hexes: [UInt32] = [0xC084FF, 0x3EE6D2, 0xFFA94D, 0xFF6B9A, 0x7CC4FF, 0xB6F36A, 0xFFD84D, 0x9D8CFF]
    static let glyphs = ["⚡", "◆", "★", "▲", "●", "✦", "■", "✚"]
    package static func glyph(_ i: Int) -> String { glyphs[((i % glyphs.count) + glyphs.count) % glyphs.count] }
}
