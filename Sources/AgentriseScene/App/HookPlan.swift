// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit
import Agentrise

package enum InstallerError: LocalizedError {
    /// Each case names the file it refused to touch ("settings.json", "hooks.json").
    case invalidJSON(String), unexpectedHooksShape(String), changedSinceRead(String), missingHelper
    package var errorDescription: String? {
        switch self {
        case .invalidJSON(let f): return "\(f) 不是有效的 JSON，没有改动它"
        case .unexpectedHooksShape(let f): return "\(f) 里的 hooks 结构不认识，没有改动它"
        case .changedSinceRead(let f): return "\(f) 刚刚被别的程序改过，请重试"
        case .missingHelper: return "找不到 agentrise-hook，请重新构建 App"
        }
    }
}

/// One agent's hooks JSON file (`{"hooks": {"<Event>": [group, …]}}`): adds or removes Agentrise's
/// entries (async unless the agent runs them synchronously anyway) and nothing else, backing the file up before every write.
package struct HookFile {
    package let url: URL
    package let events: [String]
    /// The hook command for a given helper path.
    package let command: @Sendable (String) -> String
    /// Backups are named `<file name>.<backupTag>-<yyyyMMdd-HHmmss>`.
    package let backupTag: String
    package var timeout = 5
    /// Events whose entry is not marked async (the agent would run it synchronously anyway).
    package var syncEvents: Set<String> = []

    package init(url: URL, events: [String], command: @escaping @Sendable (String) -> String, backupTag: String,
                 timeout: Int = 5, syncEvents: Set<String> = []) {
        self.url = url; self.events = events; self.command = command; self.backupTag = backupTag
        self.timeout = timeout; self.syncEvents = syncEvents
    }

    private var name: String { url.lastPathComponent }

    package func entry(hookPath: String, event: String? = nil) -> [String: Any] {
        var h: [String: Any] = ["type": "command", "command": command(hookPath), "timeout": timeout]
        if !(event.map(syncEvents.contains) ?? false) { h["async"] = true }
        return ["hooks": [h]]
    }

    package func read() throws -> (obj: [String: Any], raw: Data?) {
        guard let raw = try? Data(contentsOf: url) else { return ([:], nil) }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw InstallerError.invalidJSON(name) }
        return (obj, raw)
    }

    package func merged(_ settings: [String: Any], hookPath: String) throws -> [String: Any] {
        var s = try removed(settings)
        var hooks: [String: Any]
        if let h = s["hooks"] { guard let hh = h as? [String: Any] else { throw InstallerError.unexpectedHooksShape(name) }; hooks = hh } else { hooks = [:] }
        for ev in events {
            var groups: [Any]
            if let g = hooks[ev] { guard let gg = g as? [Any] else { throw InstallerError.unexpectedHooksShape(name) }; groups = gg } else { groups = [] }
            groups.append(entry(hookPath: hookPath, event: ev))
            hooks[ev] = groups
        }
        s["hooks"] = hooks
        return s
    }

    package func removed(_ settings: [String: Any]) throws -> [String: Any] {
        var s = settings
        guard let h = s["hooks"] else { return s }
        guard var hooks = h as? [String: Any] else { throw InstallerError.unexpectedHooksShape(name) }
        for (k, v) in hooks {
            guard let groups = v as? [Any] else { continue }
            let kept = groups.filter { !HookPlan.isOurs($0) }
            if kept.isEmpty { hooks[k] = nil } else { hooks[k] = kept }
        }
        if hooks.isEmpty { s["hooks"] = nil } else { s["hooks"] = hooks }
        return s
    }

    package func isInstalled() -> Bool {
        guard let (obj, _) = try? read(), let hooks = obj["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [Any])?.contains(where: HookPlan.isOurs) == true }
    }

    package func preview(hookPath: String) throws -> String {
        let (obj, _) = try read()
        let m = try merged(obj, hookPath: hookPath)
        let d = try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// The backup written before a change made at `date`.
    package func backupURL(at date: Date) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return url.deletingLastPathComponent().appendingPathComponent("\(name).\(backupTag)-\(f.string(from: date))")
    }

    /// Returns the backup of the previous file, if there was one.
    @discardableResult
    package func install(hookPath: String) throws -> URL? { try write { try merged($0, hookPath: hookPath) } }

    package func uninstall() throws { _ = try write { try removed($0) } }

    private func write(_ transform: ([String: Any]) throws -> [String: Any]) throws -> URL? {
        let (obj, raw) = try read()
        let out = try transform(obj)
        var backup: URL?
        if let raw {
            backup = backupURL(at: Date())
            try raw.write(to: backup!)
        }
        // Another program may have written meanwhile.
        if (try? Data(contentsOf: url)) != raw { throw InstallerError.changedSinceRead(name) }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .withoutEscapingSlashes])
        #if os(Windows)
        // Foundation has no `replaceItemAt` on Windows; its atomic write moves a temporary file over the target.
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        #else
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(name).agentrise-tmp")
        try (data + Data("\n".utf8)).write(to: tmp)
        if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path) }
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
        #endif
        return backup
    }
}

/// Which hooks Agentrise installs into which agent, and how its own entries are recognised.
package enum HookPlan {
    package static let marker = "/Agentrise/bin/agentrise-hook"
    /// The hooks installed into Claude Code, in this order. Never PermissionRequest.
    package static let claudeEvents: [HookEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
        .stop, .stopFailure, .subagentStart, .subagentStop, .notification, .preCompact,
    ]
    /// The hooks installed into Codex, in this order.
    package static let codexEvents: [HookEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .permissionRequest, .postToolUse,
        .preCompact, .postCompact, .subagentStart, .subagentStop, .stop, .interrupt,
    ]

    package static func claudeSettingsURL(home: URL) -> URL { home.appendingPathComponent(".claude/settings.json") }

    /// `$CODEX_HOME` when set, else ~/.codex.
    package static func codexHome(env: [String: String], home: URL) -> URL {
        if let h = env["CODEX_HOME"], !h.isEmpty { return URL(fileURLWithPath: (h as NSString).expandingTildeInPath) }
        return home.appendingPathComponent(".codex")
    }

    package static func claude(home: URL) -> HookFile {
        HookFile(url: claudeSettingsURL(home: home), events: claudeEvents.map(\.rawValue),
                 command: { "\"\($0)\"" }, backupTag: "agentrise-backup")
    }

    /// Codex 0.164 clamps SessionEnd and Interrupt hooks to 3 s and runs an async SessionEnd hook synchronously,
    /// warning about each on every session start; entries that ask for neither keep its status line quiet.
    package static func codex(codexHome: URL) -> HookFile {
        HookFile(url: codexHome.appendingPathComponent("hooks.json"), events: codexEvents.map(\.rawValue),
                 command: { "\"\($0)\" --agent codex" }, backupTag: "agentrise-backup",
                 timeout: 3, syncEvents: [HookEventName.sessionEnd.rawValue])
    }

    package static func isOurs(_ group: Any) -> Bool {
        guard let g = group as? [String: Any], let hs = g["hooks"] as? [[String: Any]] else { return false }
        return hs.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    /// True once a Codex hook event has reached the app: Settings shows the Codex hook as working.
    package static let codexSeenKey = "codexSeen"

    package static func noteEvent(from agent: AgentKind?, settings: SettingsStore) {
        if agent == .codex, !settings.bool(forKey: codexSeenKey) { settings.set(true, forKey: codexSeenKey) }
    }
}
