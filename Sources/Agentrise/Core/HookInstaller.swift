import Foundation
import TowerKit

enum InstallerError: LocalizedError {
    /// Each case names the file it refused to touch ("settings.json", "hooks.json").
    case invalidJSON(String), unexpectedHooksShape(String), changedSinceRead(String), missingHelper
    var errorDescription: String? {
        switch self {
        case .invalidJSON(let f): return "\(f) 不是有效的 JSON，没有改动它"
        case .unexpectedHooksShape(let f): return "\(f) 里的 hooks 结构不认识，没有改动它"
        case .changedSinceRead(let f): return "\(f) 刚刚被别的程序改过，请重试"
        case .missingHelper: return "找不到 agentrise-hook，请重新构建 App"
        }
    }
}

/// One agent's hooks JSON file (`{"hooks": {"<Event>": [group, …]}}`): adds or removes Agentrise's
/// async entries and nothing else, backing the file up before every write.
struct HookFile {
    let url: URL
    let events: [String]
    /// The hook command for a given helper path.
    let command: @Sendable (String) -> String
    /// Backups are named `<file name>.<backupTag>-<yyyyMMdd-HHmmss>`.
    let backupTag: String

    private var name: String { url.lastPathComponent }

    func entry(hookPath: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command(hookPath), "async": true, "timeout": 5]]]
    }

    func read() throws -> (obj: [String: Any], raw: Data?) {
        guard let raw = try? Data(contentsOf: url) else { return ([:], nil) }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw InstallerError.invalidJSON(name) }
        return (obj, raw)
    }

    func merged(_ settings: [String: Any], hookPath: String) throws -> [String: Any] {
        var s = try removed(settings)
        var hooks: [String: Any]
        if let h = s["hooks"] { guard let hh = h as? [String: Any] else { throw InstallerError.unexpectedHooksShape(name) }; hooks = hh } else { hooks = [:] }
        for ev in events {
            var groups: [Any]
            if let g = hooks[ev] { guard let gg = g as? [Any] else { throw InstallerError.unexpectedHooksShape(name) }; groups = gg } else { groups = [] }
            groups.append(entry(hookPath: hookPath))
            hooks[ev] = groups
        }
        s["hooks"] = hooks
        return s
    }

    func removed(_ settings: [String: Any]) throws -> [String: Any] {
        var s = settings
        guard let h = s["hooks"] else { return s }
        guard var hooks = h as? [String: Any] else { throw InstallerError.unexpectedHooksShape(name) }
        for (k, v) in hooks {
            guard let groups = v as? [Any] else { continue }
            let kept = groups.filter { !HookInstaller.isOurs($0) }
            if kept.isEmpty { hooks[k] = nil } else { hooks[k] = kept }
        }
        if hooks.isEmpty { s["hooks"] = nil } else { s["hooks"] = hooks }
        return s
    }

    func isInstalled() -> Bool {
        guard let (obj, _) = try? read(), let hooks = obj["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [Any])?.contains(where: HookInstaller.isOurs) == true }
    }

    func preview(hookPath: String) throws -> String {
        let (obj, _) = try read()
        let m = try merged(obj, hookPath: hookPath)
        let d = try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// Returns the backup of the previous file, if there was one.
    @discardableResult
    func install(hookPath: String) throws -> URL? { try write { try merged($0, hookPath: hookPath) } }

    func uninstall() throws { _ = try write { try removed($0) } }

    private func write(_ transform: ([String: Any]) throws -> [String: Any]) throws -> URL? {
        let (obj, raw) = try read()
        let out = try transform(obj)
        var backup: URL?
        if let raw {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            backup = url.deletingLastPathComponent().appendingPathComponent("\(name).\(backupTag)-\(f.string(from: Date()))")
            try raw.write(to: backup!)
        }
        // Another program may have written meanwhile.
        if (try? Data(contentsOf: url)) != raw { throw InstallerError.changedSinceRead(name) }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .withoutEscapingSlashes])
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(name).agentrise-tmp")
        try (data + Data("\n".utf8)).write(to: tmp)
        if let perms { chmod(tmp.path, mode_t(perms.uint16Value)) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return backup
    }
}

/// Adds or removes Agentrise's async hooks in ~/.claude/settings.json and ~/.codex/hooks.json, and nothing else.
enum HookInstaller {
    static let marker = "/Agentrise/bin/agentrise-hook"
    /// The hooks installed into Claude Code, in this order. Never PermissionRequest.
    static let claudeEvents: [HookEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
        .stop, .stopFailure, .subagentStart, .subagentStop, .notification, .preCompact,
    ]
    /// The hooks installed into Codex, in this order.
    static let codexEvents: [HookEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .permissionRequest, .postToolUse,
        .preCompact, .postCompact, .subagentStart, .subagentStop, .stop, .interrupt,
    ]
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

    /// `$CODEX_HOME` when set, else ~/.codex.
    static func codexHome(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = env["CODEX_HOME"], !h.isEmpty { return URL(fileURLWithPath: (h as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static let claude = HookFile(url: settingsURL, events: claudeEvents.map(\.rawValue),
                                 command: { "\"\($0)\"" }, backupTag: "agentrise-backup")
    static let codex = HookFile(url: codexHome().appendingPathComponent("hooks.json"), events: codexEvents.map(\.rawValue),
                                command: { "\"\($0)\" --agent codex" }, backupTag: "agentrise-backup")

    static func entry(hookPath: String) -> [String: Any] { claude.entry(hookPath: hookPath) }

    static func isOurs(_ group: Any) -> Bool {
        guard let g = group as? [String: Any], let hs = g["hooks"] as? [[String: Any]] else { return false }
        return hs.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    static func read(_ url: URL = settingsURL) throws -> (obj: [String: Any], raw: Data?) {
        try HookFile(url: url, events: claude.events, command: claude.command, backupTag: claude.backupTag).read()
    }

    static func merged(_ settings: [String: Any], hookPath: String) throws -> [String: Any] {
        try claude.merged(settings, hookPath: hookPath)
    }

    static func removed(_ settings: [String: Any]) throws -> [String: Any] { try claude.removed(settings) }

    static func isInstalled() -> Bool { claude.isInstalled() }

    /// Copies the helper out of the app bundle to a stable path.
    static func installHelper() throws -> String {
        let dest = TowerPaths.hookBinaryURL()
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agentrise-hook"),
                          Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("agentrise-hook")]
        guard let src = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw InstallerError.missingHelper }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        chmod(dest.path, 0o755)
        return dest.path
    }

    static func preview() throws -> String { try claude.preview(hookPath: TowerPaths.hookBinaryURL().path) }

    @discardableResult
    static func install() throws -> URL? {
        let path = try installHelper()
        return try claude.install(hookPath: path)
    }

    static func uninstall() throws { try claude.uninstall() }

    /// Codex: copies the helper, then merges into hooks.json. Codex still has to trust the hooks (`CodexAppServer`).
    @discardableResult
    static func installCodex() throws -> URL? {
        let path = try installHelper()
        return try codex.install(hookPath: path)
    }

    static func previewCodex() throws -> String { try codex.preview(hookPath: TowerPaths.hookBinaryURL().path) }

    /// True once a Codex hook event has reached the app: Settings shows the Codex hook as working.
    static let codexSeenKey = "codexSeen"

    static func noteEvent(from agent: AgentKind?, defaults: UserDefaults = .standard) {
        if agent == .codex, !defaults.bool(forKey: codexSeenKey) { defaults.set(true, forKey: codexSeenKey) }
    }
}
