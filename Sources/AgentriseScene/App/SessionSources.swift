// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit
import Agentrise

package struct RegistryEntry {
    package var sessionId: String
    package var name: String?
    package var status: String?
    package var hostSessionId: String?
    package var entrypoint: String?
    package var cwd: String?
    package var pid: Int32?
    package var updatedAt: Date?
    /// When `pid` started, as Claude Code recorded it (nil when the file has no start time).
    package var start: ProcessStart?
}

/// When a Claude Code process started, as its registry file records it (facts §1, note 1), so a reused pid can be told
/// from the session's own process. On Windows `procStartFt` is the creation time in FILETIME ticks, and `procStart` is
/// FILETIME ticks or .NET `DateTime.Ticks`; Claude Code tells the two scales apart by size (`> 3e17`). Other platforms
/// write `procStart` in a form the app doesn't read (their `PlatformServices` ignores it).
package struct ProcessStart: Equatable {
    /// `procStartFt`, as written.
    package var fileTime: String?
    /// `procStart`, as written.
    package var procStart: String?

    package init(fileTime: String? = nil, procStart: String? = nil) {
        self.fileTime = fileTime
        self.procStart = procStart
    }

    /// The registry's fields (strings, or numbers); nil when it has neither.
    package init?(registry o: [String: Any]) {
        func text(_ v: Any?) -> String? {
            if let s = v as? String { return s.isEmpty ? nil : s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        fileTime = text(o["procStartFt"])
        procStart = text(o["procStart"])
        if fileTime == nil && procStart == nil { return nil }
    }

    /// .NET ticks (100 ns since 0001-01-01) at the FILETIME epoch (1601-01-01).
    package static let dotNetTicksAtFileTimeEpoch: UInt64 = 504_911_232_000_000_000
    /// Claude Code's line between the two scales: above it a value is .NET ticks, below it FILETIME.
    package static let dotNetThreshold: UInt64 = 300_000_000_000_000_000
    /// How far apart two readings of one creation time may be (the registry may round, e.g. through a JS number).
    package static let tolerance: UInt64 = 10_000_000   // 1 s

    /// Whether a process created at `creation` (FILETIME ticks, UTC) is the one recorded here; nil when no field is a
    /// number this can read (then only liveness counts). `procStartFt` wins over `procStart`. .NET ticks may be local
    /// time (`Win32_Process.CreationDate` is) or UTC; either reading matches. `utcOffset` gives the local zone's
    /// offset in seconds at a FILETIME.
    package func matches(creation: UInt64, utcOffset: (UInt64) -> Int = ProcessStart.localOffset) -> Bool? {
        func number(_ s: String?) -> UInt64? {
            guard let s = s?.trimmingCharacters(in: .whitespaces) else { return nil }
            if let n = UInt64(s) { return n }
            // A JS number past 2^53 may be written in exponent form.
            guard let d = Double(s), d.isFinite, d >= 0, d < 1.8e19 else { return nil }
            return UInt64(d)
        }
        func near(_ a: UInt64, _ b: UInt64) -> Bool { (a > b ? a - b : b - a) <= Self.tolerance }
        if let ft = number(fileTime) { return near(ft, creation) }
        guard let v = number(procStart) else { return nil }
        guard v > Self.dotNetThreshold else { return near(v, creation) }
        let utc = creation + Self.dotNetTicksAtFileTimeEpoch
        let offset = Int64(utcOffset(creation)) * 10_000_000
        let local = UInt64(clamping: Int64(clamping: utc) + offset)
        return near(v, utc) || near(v, local)
    }

    /// The current time zone's offset from UTC, in seconds, at a FILETIME.
    package static func localOffset(_ fileTime: UInt64) -> Int {
        let seconds = Double(fileTime) / 10_000_000 - 11_644_473_600   // FILETIME epoch → Unix epoch
        return TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: seconds))
    }
}

/// ~/.claude/sessions/<pid>.json, written by every live Claude Code process (Windows: `%USERPROFILE%\.claude\sessions`,
/// or `%CLAUDE_CONFIG_DIR%\sessions`; facts §1).
package enum SessionRegistry {
    package static func dir(home: URL) -> URL { home.appendingPathComponent(".claude/sessions") }

    /// `<Claude Code's config dir>/sessions`.
    package static func dir(claudeDir: URL) -> URL { claudeDir.appendingPathComponent("sessions") }

    package static func load(home: URL, isRunning: (Int32) -> Bool) -> [String: RegistryEntry] {
        load(dir: dir(home: home), isRunning: isRunning)
    }

    package static func load(dir: URL, isRunning: (Int32) -> Bool) -> [String: RegistryEntry] {
        load(dir: dir, isSameProcess: { pid, _ in isRunning(pid) })
    }

    /// Entries whose process is still the one that wrote them: `isSameProcess(pid, start)` is false for a process
    /// that is gone, and (Windows) for a reused pid whose creation time isn't the recorded `start`.
    package static func load(dir: URL, isSameProcess: (Int32, ProcessStart?) -> Bool) -> [String: RegistryEntry] {
        var out: [String: RegistryEntry] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let sid = o["sessionId"] as? String else { continue }
            let pid = (o["pid"] as? NSNumber)?.int32Value
            let start = ProcessStart(registry: o)
            if let pid, !isSameProcess(pid, start) { continue }   // stale file
            let ms = ((o["statusUpdatedAt"] ?? o["updatedAt"] ?? o["startedAt"]) as? NSNumber)?.doubleValue
            out[sid] = RegistryEntry(sessionId: sid, name: o["name"] as? String, status: o["status"] as? String,
                                     hostSessionId: o["hostSessionId"] as? String, entrypoint: o["entrypoint"] as? String,
                                     cwd: o["cwd"] as? String, pid: pid,
                                     updatedAt: ms.map { Date(timeIntervalSince1970: $0 / 1000) }, start: start)
        }
        return out
    }
}

/// cc-connect (Feishu bridge) remembers which Claude session belongs to which chat.
extension CCConnectIndex {
    package static func dir(home: URL) -> URL { home.appendingPathComponent(".cc-connect/sessions") }

    package static func load(home: URL, enabled: Bool = enabled) -> [String: String] {
        var out: [String: String] = [:]
        guard enabled else { return out }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir(home: home), includingPropertiesForKeys: nil)) ?? []
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
package enum CodexSessionIndex {
    package static func file(home: URL) -> URL { home.appendingPathComponent(".codex/session_index.jsonl") }

    /// `<Codex's home>/session_index.jsonl`.
    package static func file(codexHome: URL) -> URL { codexHome.appendingPathComponent("session_index.jsonl") }

    package struct Stamp: Equatable { package var modified: Date?; package var size: Int? }

    /// Cheap change detector: the file's modification time and size (both nil when it is missing).
    package static func stamp(of url: URL) -> Stamp {
        // Not URL.resourceValues: a URL caches them, and this one is long-lived.
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Stamp(modified: a?[.modificationDate] as? Date, size: (a?[.size] as? NSNumber)?.intValue)
    }

    /// Session id → thread name; a later line for the same id wins. Unreadable lines are skipped.
    package static func load(from url: URL) -> [String: String] {
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

package enum TranscriptModelReader {
    package static func model(transcriptPath: String?, sessionId: String, home: URL) -> String? {
        model(transcriptPath: transcriptPath, sessionId: sessionId, claudeDir: home.appendingPathComponent(".claude"))
    }

    package static func model(transcriptPath: String?, sessionId: String, claudeDir: URL) -> String? {
        var path = transcriptPath
        if path == nil {
            let projects = claudeDir.appendingPathComponent("projects")
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

package enum SessionResolver {
    package static func context(sessionId: String, event: SlimEvent?, registry: [String: RegistryEntry],
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
    package static func codexContext(sessionId: String, cwd: String?, bundleId: String?, model: String?,
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
package enum CodexCommandLine {
    /// Global options that take a value, so `codex -c k=v exec …` still finds `exec`.
    private static let valued: Set<String> = ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox",
                                              "-C", "--cd", "-a", "--ask-for-approval", "-i", "--image",
                                              "--enable", "--disable", "--add-dir", "--local-provider", "--remote"]

    /// True for `codex exec …` (alias `e`): the first word after the global options is the subcommand.
    package static func isHeadless(_ argv: [String]) -> Bool {
        var it = argv.dropFirst().makeIterator()
        while let a = it.next() {
            if valued.contains(a) { _ = it.next(); continue }
            if a.hasPrefix("-") { continue }
            return a == "exec" || a == "e"
        }
        return false
    }
}

/// Where clicking a session goes: the Claude app's deep link, or the terminal app that ran it. `pid` is the agent's
/// process (the registry's, else the hook's `agentPid`): Windows finds the terminal window by walking up from it.
/// `start` is the registry's record of when that process started, so Windows doesn't follow a reused pid.
package enum SessionLink: Equatable {
    case desktop(URL)
    case terminal(bundleId: String?, pid: Int32? = nil, start: ProcessStart? = nil)

    package static func url(hostSessionId: String) -> URL? { URL(string: "claude://claude.ai/epitaxy/\(hostSessionId)") }
}
