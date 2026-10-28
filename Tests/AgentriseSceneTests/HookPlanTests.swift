// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit
@testable import Agentrise
@testable import AgentriseScene

/// An in-memory `SettingsStore`.
final class MemorySettings: SettingsStore {
    var values: [String: Bool] = [:]
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}

@Suite struct HookPlanTests {
    private let hookPath = "/Users/u/Library/Application Support/Agentrise/bin/agentrise-hook"

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agentrise-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func json(_ url: URL) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
    }

    @Test func codexInstallKeepsUserHooks() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("hooks.json")
        let original = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo bye"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"lint.sh"}]}]},"other":1}"#
        try Data(original.utf8).write(to: url)
        let file = HookPlan.codex(codexHome: dir)
        #expect(file.url == url)
        #expect(!file.isInstalled())

        let backup = try file.install(hookPath: hookPath)
        #expect(file.isInstalled())
        #expect(backup?.lastPathComponent.hasPrefix("hooks.json.agentrise-backup-") == true)
        let out = try json(url)
        #expect(out["other"] as? Int == 1)
        let hooks = try #require(out["hooks"] as? [String: [[String: Any]]])
        let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                      "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop", "Interrupt"]
        #expect(file.events == events)
        #expect(Set(hooks.keys) == Set(events))
        for ev in events {
            let ours = try #require(hooks[ev]).filter { HookPlan.isOurs($0) }
            #expect(ours.count == 1, "\(ev)")
            let h = try #require((ours.first?["hooks"] as? [[String: Any]])?.first)
            #expect(h["type"] as? String == "command")
            #expect(h["command"] as? String == "\"\(hookPath)\" --agent codex")
            #expect((h["command"] as? String)?.hasSuffix("--agent codex") == true)
            // Codex 0.164 warns on every session start about an async SessionEnd and a timeout over 3 s.
            #expect(h["async"] as? Bool == (ev == "SessionEnd" ? nil : true), "\(ev)")
            #expect(h["timeout"] as? Int == 3)
            #expect(ours.first?["matcher"] == nil)
        }
        #expect((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "echo bye")
        #expect(hooks["PreToolUse"]?.first?["matcher"] as? String == "Bash")

        // Installing twice still leaves one entry per event.
        _ = try file.install(hookPath: hookPath)
        let again = try #require(try json(url)["hooks"] as? [String: [Any]])
        #expect(again["Stop"]?.filter(HookPlan.isOurs).count == 1)

        try file.uninstall()
        #expect(!file.isInstalled())
        #expect(try json(url) == (try JSONSerialization.jsonObject(with: Data(original.utf8)) as! NSDictionary))
    }

    @Test(arguments: ["[1,2]", #"{"hooks": 3}"#, "not json"])
    func codexInstallRejectsBadFile(_ content: String) throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("hooks.json")
        try Data(content.utf8).write(to: url)
        let file = HookPlan.codex(codexHome: dir)
        #expect(throws: InstallerError.self) { try file.install(hookPath: hookPath) }
        #expect(throws: InstallerError.self) { try file.preview(hookPath: hookPath) }
        #expect(String(data: try Data(contentsOf: url), encoding: .utf8) == content)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["hooks.json"])
    }

    @Test func codexErrorsNameHooksJSON() {
        #expect(InstallerError.invalidJSON("hooks.json").errorDescription == "hooks.json 不是有效的 JSON，没有改动它")
        #expect(InstallerError.invalidJSON("settings.json").errorDescription == "settings.json 不是有效的 JSON，没有改动它")
        #expect(InstallerError.unexpectedHooksShape("settings.json").errorDescription == "settings.json 里的 hooks 结构不认识，没有改动它")
        #expect(InstallerError.changedSinceRead("settings.json").errorDescription == "settings.json 刚刚被别的程序改过，请重试")
    }

    /// The Claude plan against the merge recorded before `HookInstaller.merged` moved into `HookFile`.
    @Test func claudePlanMatchesTheRecordedMerge() throws {
        let golden = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AgentriseAppTests/Fixtures/claude-installer-merged.json"), encoding: .utf8)
        let input = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\"/old/Agentrise/bin/agentrise-hook\"","async":true,"timeout":5}]}]}}"#
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let home = try tempDir()
        let file = HookPlan.claude(home: home)
        #expect(file.url == home.appendingPathComponent(".claude/settings.json"))
        #expect(file.events == HookPlan.claudeEvents.map(\.rawValue))
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(input.utf8).write(to: file.url)
        #expect(try file.preview(hookPath: hookPath) == golden)
        let backup = try file.install(hookPath: hookPath)
        #expect(backup?.lastPathComponent.hasPrefix("settings.json.agentrise-backup-") == true)
        #expect(try Data(contentsOf: try #require(backup)) == Data(input.utf8))
        let written = try Data(contentsOf: file.url)
        #expect(written.last == UInt8(ascii: "\n"))
        let back = try JSONSerialization.jsonObject(with: written)
        #expect(String(data: try JSONSerialization.data(withJSONObject: back, options: opts), encoding: .utf8) == golden)
        let dir = file.url.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["settings.json", backup!.lastPathComponent].sorted())
    }

    @Test func backupIsNamedAfterTheFileTagAndTime() throws {
        let file = HookPlan.claude(home: try tempDir())
        // Local time, like the formatter.
        let parts = DateComponents(year: 2026, month: 10, day: 29, hour: 7, minute: 5, second: 9)
        let date = try #require(Calendar.current.date(from: parts))
        let backup = file.backupURL(at: date)
        #expect(backup.lastPathComponent == "settings.json.agentrise-backup-20261029-070509")
        #expect(backup.deletingLastPathComponent() == file.url.deletingLastPathComponent())
        #expect(HookPlan.codex(codexHome: try tempDir()).backupURL(at: date).lastPathComponent == "hooks.json.agentrise-backup-20261029-070509")
    }

    @Test func codexHomeHonoursEnvironment() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home")
        #expect(HookPlan.codexHome(env: ["CODEX_HOME": "/tmp/cx"], home: home) == URL(fileURLWithPath: "/tmp/cx"))
        #expect(HookPlan.codexHome(env: ["CODEX_HOME": ""], home: home) == home.appendingPathComponent(".codex"))
        #expect(HookPlan.codexHome(env: [:], home: home) == home.appendingPathComponent(".codex"))
        #expect(HookPlan.codex(codexHome: home).url == home.appendingPathComponent("hooks.json"))
    }

    @Test func firstCodexEventMarksCodexSeen() {
        let settings = MemorySettings()
        HookPlan.noteEvent(from: nil, settings: settings)
        HookPlan.noteEvent(from: .claude, settings: settings)
        #expect(settings.values.isEmpty)
        HookPlan.noteEvent(from: .codex, settings: settings)
        #expect(settings.values == ["codexSeen": true])
    }
}
