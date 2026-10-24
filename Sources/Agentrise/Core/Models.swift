import Foundation
import AppKit

enum Rank: String, CaseIterable {
    case seniorDirector, seniorExpert, seniorEngineer, newGrad

    var title: String {
        switch self {
        case .seniorDirector: return "资深总监"
        case .seniorExpert: return "高级专家"
        case .seniorEngineer: return "高级工程师"
        case .newGrad: return "校招生"
        }
    }

    /// Color of the light strip on the robot's body.
    var stripe: NSColor {
        switch self {
        case .seniorDirector: return NSColor(hex: 0xFFCF3F)
        case .seniorExpert: return NSColor(hex: 0xC084FF)
        case .seniorEngineer: return NSColor(hex: 0x4CC3FF)
        case .newGrad: return NSColor(hex: 0x6FF0A8)
        }
    }

    static func from(model: String?) -> Rank {
        let m = (model ?? "").lowercased()
        if m.contains("fable") { return .seniorDirector }
        if m.contains("opus") { return .seniorExpert }
        if m.contains("haiku") { return .newGrad }
        return .seniorEngineer
    }
}

enum Activity: String {
    case reading, searching, coding, runningCommand, commandFailed, browsing, planning,
         delegating, sendingLark, thinking, compacting, waitingAtDoor, waitingForSubs, reporting, resting, standby,
         sleeping, briefing, other

    var label: String {
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

enum Room: String, CaseIterable {
    case meeting, ceoOffice, desks, whiteboard, intel, archive, pantry, mailroom, serverRoom, sleepPods

    var title: String {
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

enum ActivityMap {
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
    static func room(for a: Activity) -> Room? {
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

enum SessionStatus: String {
    case working, waiting, done, error, standby, sleeping
}

enum SessionSource: Equatable {
    case desktop(hostSessionId: String?)
    case lark
    case terminal(bundleId: String?)
}

struct SubAgent: Equatable {
    var id: String
    var type: String
    var activity: Activity
    var startedAt: Date
}

struct Contractor: Equatable {
    var id: String
    var description: String
    var startedAt: Date
}

struct Session: Equatable {
    var id: String
    var title: String
    var source: SessionSource
    var rank: Rank
    var status: SessionStatus
    var activity: Activity
    var teamIndex: Int
    var subs: [String: SubAgent] = [:]
    var contractors: [String: Contractor] = [:]
    var delivered = 0
    var failedSubs = 0
    var contractorsDone = 0
    var larkSent = false
    var waitingSummary: String?
    var transientErrorAt: Date?
    var statusSince: Date
    var lastActivityAt: Date
    var cwd: String?
    var transcriptPath: String?
    var isHidden = false
    var modelKnown = false
    var lastSeenInRegistry: Date?

    var isLark: Bool { source == .lark }
}

struct TowerCounts: Equatable {
    var working = 0, waiting = 0, done = 0, subs = 0, contractors = 0, sleeping = 0, standby = 0
}

enum TowerEffect: Equatable {
    case statusChanged(sessionId: String, from: SessionStatus, to: SessionStatus)
    case subFinished(sessionId: String, subId: String, success: Bool)
    case contractorFinished(sessionId: String, contractorId: String)
    case sessionLeft(sessionId: String)
}

/// Team identity of a main agent: halo color + emblem glyph.
enum Team {
    static let colors: [NSColor] = [0xC084FF, 0x3EE6D2, 0xFFA94D, 0xFF6B9A, 0x7CC4FF, 0xB6F36A, 0xFFD84D, 0x9D8CFF].map { NSColor(hex: $0) }
    static let glyphs = ["⚡", "◆", "★", "▲", "●", "✦", "■", "✚"]
    static func color(_ i: Int) -> NSColor { colors[((i % colors.count) + colors.count) % colors.count] }
    static func glyph(_ i: Int) -> String { glyphs[((i % glyphs.count) + glyphs.count) % glyphs.count] }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
