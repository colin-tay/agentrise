import Foundation
import TowerKit

struct RegistryEntry {
    var sessionId: String
    var name: String?
    var status: String?
    var hostSessionId: String?
    var entrypoint: String?
    var cwd: String?
    var pid: Int32?
    var updatedAt: Date?
}

/// ~/.claude/sessions/<pid>.json, written by every live Claude Code process.
enum SessionRegistry {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")

    static func load() -> [String: RegistryEntry] {
        var out: [String: RegistryEntry] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let sid = o["sessionId"] as? String else { continue }
            let pid = (o["pid"] as? NSNumber)?.int32Value
            if let pid, kill(pid, 0) != 0, errno == ESRCH { continue }   // stale file
            let ms = ((o["statusUpdatedAt"] ?? o["updatedAt"] ?? o["startedAt"]) as? NSNumber)?.doubleValue
            out[sid] = RegistryEntry(sessionId: sid, name: o["name"] as? String, status: o["status"] as? String,
                                     hostSessionId: o["hostSessionId"] as? String, entrypoint: o["entrypoint"] as? String,
                                     cwd: o["cwd"] as? String, pid: pid,
                                     updatedAt: ms.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        return out
    }
}

/// cc-connect (Feishu bridge) remembers which Claude session belongs to which chat.
/// Off by default: only users who run cc-connect turn it on in Settings.
enum CCConnectIndex {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cc-connect/sessions")

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "feishuBridge") }
        set { UserDefaults.standard.set(newValue, forKey: "feishuBridge") }
    }

    static func load() -> [String: String] {
        var out: [String: String] = [:]
        guard enabled else { return out }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let sessions = o["sessions"] as? [String: Any] else { continue }
            for (_, v) in sessions {
                guard let s = v as? [String: Any] else { continue }
                let name = (s["name"] as? String) ?? ""
                if let a = s["agent_session_id"] as? String, !a.isEmpty { out[a] = name }
                for p in (s["past_agent_session_ids"] as? [String]) ?? [] { out[p] = name }
            }
        }
        return out
    }
}

enum TranscriptModelReader {
    static func model(transcriptPath: String?, sessionId: String) -> String? {
        var path = transcriptPath
        if path == nil {
            let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            path = dirs.map { $0.appendingPathComponent("\(sessionId).jsonl").path }
                .first { FileManager.default.fileExists(atPath: $0) }
        }
        guard let p = path, let fh = FileHandle(forReadingAtPath: p) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        guard let r = text.range(of: "\"model\":\"claude-[^\"]+\"", options: [.regularExpression, .backwards]) else { return nil }
        return String(text[r]).replacingOccurrences(of: "\"model\":", with: "").replacingOccurrences(of: "\"", with: "")
    }
}

enum SessionResolver {
    static func context(sessionId: String, event: SlimEvent?, registry: [String: RegistryEntry],
                        cc: [String: String], larkNumbers: inout [String: Int]) -> SessionContext {
        let reg = registry[sessionId]
        let entry = event?.entrypoint ?? reg?.entrypoint
        let cwd = event?.cwd ?? reg?.cwd
        let folder = cwd.map { ($0 as NSString).lastPathComponent } ?? "会话"
        var ctx = SessionContext()
        ctx.model = event?.model

        if let larkName = cc[sessionId] {
            ctx.source = .lark
            if !larkName.isEmpty { ctx.title = larkName } else {
                if larkNumbers[sessionId] == nil { larkNumbers[sessionId] = larkNumbers.count + 1 }
                ctx.title = "飞书会话 \(larkNumbers[sessionId]!)"
            }
        } else if entry == "claude-desktop" || entry == "claude-desktop-3p" {
            // The app also runs short internal sessions (titles, suggestions) that never reach the
            // sidebar; only sessions in the registry are real ones.
            ctx.source = reg == nil ? nil : .desktop(hostSessionId: reg?.hostSessionId)
            ctx.title = reg?.name ?? event?.sessionTitle ?? folder
        } else if entry == "cli" || (entry == nil && reg != nil) {
            ctx.source = .terminal(bundleId: event?.bundleId)
            ctx.title = event?.sessionTitle ?? reg?.name ?? "\(folder) · 终端"
        } else {
            ctx.source = nil  // headless run (claude -p, SDK): not shown
            ctx.title = event?.sessionTitle ?? folder
        }
        return ctx
    }
}

enum SessionLink {
    static func url(hostSessionId: String) -> URL? { URL(string: "claude://claude.ai/epitaxy/\(hostSessionId)") }
}
