import Foundation
import TowerKit

enum InstallerError: LocalizedError {
    case invalidJSON, unexpectedHooksShape, changedSinceRead, missingHelper
    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "settings.json 不是有效的 JSON，没有改动它"
        case .unexpectedHooksShape: return "settings.json 里的 hooks 结构不认识，没有改动它"
        case .changedSinceRead: return "settings.json 刚刚被别的程序改过，请重试"
        case .missingHelper: return "找不到 agentrise-hook，请重新构建 App"
        }
    }
}

/// Adds or removes Agentrise's async hooks in ~/.claude/settings.json and nothing else.
enum HookInstaller {
    static let marker = "/Agentrise/bin/agentrise-hook"
    /// The hooks installed into Claude Code, in this order. Never PermissionRequest.
    static let claudeEvents: [HookEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
        .stop, .stopFailure, .subagentStart, .subagentStop, .notification, .preCompact,
    ]
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

    static func entry(hookPath: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": "\"\(hookPath)\"", "async": true, "timeout": 5]]]
    }

    static func isOurs(_ group: Any) -> Bool {
        guard let g = group as? [String: Any], let hs = g["hooks"] as? [[String: Any]] else { return false }
        return hs.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    static func read(_ url: URL = settingsURL) throws -> (obj: [String: Any], raw: Data?) {
        guard let raw = try? Data(contentsOf: url) else { return ([:], nil) }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw InstallerError.invalidJSON }
        return (obj, raw)
    }

    static func merged(_ settings: [String: Any], hookPath: String) throws -> [String: Any] {
        var s = try removed(settings)
        var hooks: [String: Any]
        if let h = s["hooks"] { guard let hh = h as? [String: Any] else { throw InstallerError.unexpectedHooksShape }; hooks = hh } else { hooks = [:] }
        for ev in claudeEvents {
            var groups: [Any]
            if let g = hooks[ev.rawValue] { guard let gg = g as? [Any] else { throw InstallerError.unexpectedHooksShape }; groups = gg } else { groups = [] }
            groups.append(entry(hookPath: hookPath))
            hooks[ev.rawValue] = groups
        }
        s["hooks"] = hooks
        return s
    }

    static func removed(_ settings: [String: Any]) throws -> [String: Any] {
        var s = settings
        guard let h = s["hooks"] else { return s }
        guard var hooks = h as? [String: Any] else { throw InstallerError.unexpectedHooksShape }
        for (k, v) in hooks {
            guard let groups = v as? [Any] else { continue }
            let kept = groups.filter { !isOurs($0) }
            if kept.isEmpty { hooks[k] = nil } else { hooks[k] = kept }
        }
        if hooks.isEmpty { s["hooks"] = nil } else { s["hooks"] = hooks }
        return s
    }

    static func isInstalled() -> Bool {
        guard let (obj, _) = try? read(), let hooks = obj["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [Any])?.contains(where: isOurs) == true }
    }

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

    static func preview() throws -> String {
        let (obj, _) = try read()
        let m = try merged(obj, hookPath: TowerPaths.hookBinaryURL().path)
        let d = try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(data: d, encoding: .utf8) ?? ""
    }

    @discardableResult
    static func install() throws -> URL? {
        let path = try installHelper()
        return try write { try merged($0, hookPath: path) }
    }

    static func uninstall() throws { _ = try write { try removed($0) } }

    private static func write(_ transform: ([String: Any]) throws -> [String: Any]) throws -> URL? {
        let url = settingsURL
        let (obj, raw) = try read(url)
        let out = try transform(obj)
        var backup: URL?
        if let raw {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.agentrise-backup-\(f.string(from: Date()))")
            try raw.write(to: backup!)
        }
        // Another program may have written meanwhile.
        if (try? Data(contentsOf: url)) != raw { throw InstallerError.changedSinceRead }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .withoutEscapingSlashes])
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".settings.json.agentrise-tmp")
        try (data + Data("\n".utf8)).write(to: tmp)
        if let perms { chmod(tmp.path, mode_t(perms.uint16Value)) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return backup
    }
}
