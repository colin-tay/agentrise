// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit
import Agentrise

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
extension CCConnectIndex {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cc-connect/sessions")

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

/// ~/.codex/session_index.jsonl: one `{id, thread_name, updated_at}` per line, appended on every rename.
enum CodexSessionIndex {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl")

    struct Stamp: Equatable { var modified: Date?; var size: Int? }

    /// Cheap change detector: the file's modification time and size (both nil when it is missing).
    static func stamp(of url: URL = file) -> Stamp {
        // Not URL.resourceValues: a URL caches them, and this one is long-lived.
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Stamp(modified: a?[.modificationDate] as? Date, size: (a?[.size] as? NSNumber)?.intValue)
    }

    /// Session id → thread name; a later line for the same id wins. Unreadable lines are skipped.
    static func load(from url: URL = file) -> [String: String] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = o["id"] as? String, let name = o["thread_name"] as? String,
                  !id.isEmpty, !name.isEmpty else { continue }
            out[id] = name
        }
        return out
    }
}

enum ProcessProbe {
    /// False only when the process is known to be gone (no permission to signal it still counts as running).
    static func isRunning(_ pid: Int32) -> Bool { !(kill(pid, 0) == -1 && errno == ESRCH) }
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
                        cc: [String: String], larkNumbers: inout [String: Int],
                        codexIndex: [String: String] = [:],
                        arguments: (Int32) -> [String]? = ProcessAncestry.arguments(of:)) -> SessionContext {
        if event?.agent == .codex {
            let headless = event?.agentPid.flatMap(arguments).map(CodexCommandLine.isHeadless) ?? false
            return codexContext(sessionId: sessionId, cwd: event?.cwd, bundleId: event?.bundleId,
                                // A subagent may run another model; only the main agent's events rank the robot.
                                model: event?.agentId == nil ? event?.model : nil, index: codexIndex, headless: headless)
        }
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

    /// Codex has no registry: the title comes from its session index, the source is whatever app ran
    /// the hook, and every event carries the model. A `codex exec` run (`headless`) is not shown.
    static func codexContext(sessionId: String, cwd: String?, bundleId: String?, model: String?,
                             index: [String: String], headless: Bool = false) -> SessionContext {
        let folder = cwd.map { ($0 as NSString).lastPathComponent } ?? "会话"
        var ctx = SessionContext()
        ctx.agent = .codex
        ctx.source = headless ? nil : .terminal(bundleId: bundleId)
        ctx.title = index[sessionId] ?? "\(folder) · 终端"
        ctx.model = model
        return ctx
    }
}

/// Codex's hooks carry nothing that tells `codex exec` apart (same `source`, no env var), so the
/// command line of the hook's `codex` process (`agentPid`) is read instead.
enum CodexCommandLine {
    /// Global options that take a value, so `codex -c k=v exec …` still finds `exec`.
    private static let valued: Set<String> = ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox",
                                              "-C", "--cd", "-a", "--ask-for-approval", "-i", "--image",
                                              "--enable", "--disable", "--add-dir", "--local-provider", "--remote"]

    /// True for `codex exec …` (alias `e`): the first word after the global options is the subcommand.
    static func isHeadless(_ argv: [String]) -> Bool {
        var it = argv.dropFirst().makeIterator()
        while let a = it.next() {
            if valued.contains(a) { _ = it.next(); continue }
            if a.hasPrefix("-") { continue }
            return a == "exec" || a == "e"
        }
        return false
    }
}

enum SessionLink {
    static func url(hostSessionId: String) -> URL? { URL(string: "claude://claude.ai/epitaxy/\(hostSessionId)") }
}
