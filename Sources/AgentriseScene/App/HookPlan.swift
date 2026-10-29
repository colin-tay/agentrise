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
    /// The command fields of a handler for a given helper path.
    package let handler: @Sendable (String) -> HookCommand
    /// Backups are named `<file name>.<backupTag>-<yyyyMMdd-HHmmss>`.
    package let backupTag: String
    package var timeout = 5
    /// Events whose entry is not marked async (the agent would run it synchronously anyway).
    package var syncEvents: Set<String> = []

    package init(url: URL, events: [String], handler: @escaping @Sendable (String) -> HookCommand, backupTag: String,
                 timeout: Int = 5, syncEvents: Set<String> = []) {
        self.url = url; self.events = events; self.handler = handler; self.backupTag = backupTag
        self.timeout = timeout; self.syncEvents = syncEvents
    }

    /// A file whose handlers are a single `command` string (the macOS form).
    package init(url: URL, events: [String], command: @escaping @Sendable (String) -> String, backupTag: String,
                 timeout: Int = 5, syncEvents: Set<String> = []) {
        self.init(url: url, events: events, handler: { HookCommand(command: command($0)) }, backupTag: backupTag,
                  timeout: timeout, syncEvents: syncEvents)
    }

    /// The `command` string of a handler for a given helper path.
    package var command: @Sendable (String) -> String { { [handler] in handler($0).command } }

    private var name: String { url.lastPathComponent }

    package func entry(hookPath: String, event: String? = nil) -> [String: Any] {
        var h: [String: Any] = ["type": "command", "timeout": timeout]
        for (k, v) in handler(hookPath).fields { h[k] = v }
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
            #if os(Windows)
            try SafeFile.write(raw, to: backup!)
            #else
            try raw.write(to: backup!)
            #endif
        }
        // Another program may have written meanwhile.
        if (try? Data(contentsOf: url)) != raw { throw InstallerError.changedSinceRead(name) }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .withoutEscapingSlashes])
        #if os(Windows)
        // Foundation has no `replaceItemAt` on Windows, and its atomic write races child processes (see `SafeFile`).
        try SafeFile.write(data + Data("\n".utf8), to: url)
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

/// Which platform's spelling a hook handler uses.
package enum HookPlatform: Equatable {
    /// macOS: one `command` string run by `sh -c`, the helper's path in double quotes.
    case posix
    /// Windows (facts §2, §4). Claude Code: exec form (`command` is the exe, `args` its arguments, no shell), or the
    /// documented fallback for versions without `args`: `"shell": "powershell"` with `& '<path>' --agent claude`.
    /// Codex has no exec form; it runs `commandWindows` in PowerShell (`& '<path>' --agent codex`) and ignores `shell`.
    case windows(WindowsHookShell)

    /// What this build writes: `.posix` on macOS, Claude Code's exec form on Windows.
    package static var current: HookPlatform {
        #if os(Windows)
        return .windows(.exec)
        #else
        return .posix
        #endif
    }
}

/// How Claude Code on Windows runs Agentrise's hook.
package enum WindowsHookShell: Equatable { case exec, powershell }

/// The fields of one hook handler that say what to run (`type`, `timeout` and `async` are `HookFile`'s).
package struct HookCommand: Equatable {
    package var command: String
    /// Claude Code's exec form: the argument vector (`command` is then the executable).
    package var args: [String]?
    /// Claude Code: the shell that runs `command` ("powershell"); ignored when `args` is set.
    package var shell: String?
    /// Codex on Windows: used instead of `command` there.
    package var commandWindows: String?

    package init(command: String, args: [String]? = nil, shell: String? = nil, commandWindows: String? = nil) {
        self.command = command; self.args = args; self.shell = shell; self.commandWindows = commandWindows
    }

    /// The JSON fields, only those that are set.
    package var fields: [String: Any] {
        var f: [String: Any] = ["command": command]
        if let args { f["args"] = args }
        if let shell { f["shell"] = shell }
        if let commandWindows { f["commandWindows"] = commandWindows }
        return f
    }
}

/// Which hooks Agentrise installs into which agent, and how its own entries are recognised.
package enum HookPlan {
    package static let marker = "/Agentrise/bin/agentrise-hook"
    /// The same directory as Windows spells it (`%LOCALAPPDATA%\Agentrise\bin\agentrise-hook.exe`).
    package static let windowsMarker = "\\Agentrise\\bin\\agentrise-hook"
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

    /// `$CLAUDE_CONFIG_DIR` when set, else ~/.claude (facts §1, §3; the Windows app reads it, macOS keeps ~/.claude).
    package static func claudeConfigDir(env: [String: String], home: URL) -> URL {
        if let d = env["CLAUDE_CONFIG_DIR"], !d.isEmpty { return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true) }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// `$CODEX_HOME` when set, else ~/.codex.
    package static func codexHome(env: [String: String], home: URL) -> URL {
        if let h = env["CODEX_HOME"], !h.isEmpty { return URL(fileURLWithPath: (h as NSString).expandingTildeInPath) }
        return home.appendingPathComponent(".codex")
    }

    /// The command fields that run the helper at `hookPath` for `agent`.
    package static func command(hookPath: String, agent: AgentKind, platform: HookPlatform) -> HookCommand {
        switch (platform, agent) {
        case (.posix, .claude): return HookCommand(command: "\"\(hookPath)\"")
        case (.posix, .codex): return HookCommand(command: "\"\(hookPath)\" --agent codex")
        case (.windows(.exec), .claude): return HookCommand(command: hookPath, args: ["--agent", "claude"])
        case (.windows(.powershell), .claude):
            return HookCommand(command: "& \(powerShellQuoted(hookPath)) --agent claude", shell: "powershell")
        case (.windows, .codex):
            return HookCommand(command: "\"\(hookPath)\" --agent codex",
                               commandWindows: "& \(powerShellQuoted(hookPath)) --agent codex")
        }
    }

    /// A PowerShell single-quoted string: a quote inside is doubled. PowerShell also takes the typographic single
    /// quotes (U+2018–U+201B) as quotes, so they are doubled too.
    package static func powerShellQuoted(_ s: String) -> String {
        var out = "'"
        for c in s {
            out.append(c)
            if c == "'" || c == "\u{2018}" || c == "\u{2019}" || c == "\u{201A}" || c == "\u{201B}" { out.append(c) }
        }
        return out + "'"
    }

    /// The macOS form unless asked otherwise (the Windows app always passes `.windows`).
    package static func claude(home: URL, platform: HookPlatform = .posix) -> HookFile {
        claude(settings: claudeSettingsURL(home: home), platform: platform)
    }

    /// Claude Code's user settings at `settings` (`<config dir>/settings.json`).
    package static func claude(settings: URL, platform: HookPlatform) -> HookFile {
        HookFile(url: settings, events: claudeEvents.map(\.rawValue),
                 handler: { command(hookPath: $0, agent: .claude, platform: platform) }, backupTag: "agentrise-backup")
    }

    /// Codex 0.164 clamps SessionEnd and Interrupt hooks to 3 s and runs an async SessionEnd hook synchronously,
    /// warning about each on every session start; entries that ask for neither keep its status line quiet.
    package static func codex(codexHome: URL, platform: HookPlatform = .posix) -> HookFile {
        HookFile(url: codexHome.appendingPathComponent("hooks.json"), events: codexEvents.map(\.rawValue),
                 handler: { command(hookPath: $0, agent: .codex, platform: platform) }, backupTag: "agentrise-backup",
                 timeout: 3, syncEvents: [HookEventName.sessionEnd.rawValue])
    }

    package static func isOurs(_ group: Any) -> Bool {
        guard let g = group as? [String: Any], let hs = g["hooks"] as? [[String: Any]] else { return false }
        return hs.contains { isOurs(handler: $0) }
    }

    /// A handler (or an app-server's listing of one) that runs Agentrise's helper, in either platform's spelling.
    package static func isOurs(handler h: [String: Any]) -> Bool {
        ["command", "commandWindows"].contains { (h[$0] as? String).map(isOurCommand) == true }
    }

    package static func isOurCommand(_ c: String) -> Bool { c.contains(marker) || c.contains(windowsMarker) }

    /// True once a Codex hook event has reached the app: Settings shows the Codex hook as working.
    package static let codexSeenKey = "codexSeen"

    package static func noteEvent(from agent: AgentKind?, settings: SettingsStore) {
        if agent == .codex, !settings.bool(forKey: codexSeenKey) { settings.set(true, forKey: codexSeenKey) }
    }
}
