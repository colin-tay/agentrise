// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit
@testable import Agentrise
@testable import AgentriseScene

/// The hook handler each platform writes (facts §2, §4). These run on both platforms: the Windows spelling is plain
/// string and JSON work.
@Suite struct HookCommandTests {
    private let winPath = "C:\\Users\\张 三\\AppData\\Local\\Agentrise\\bin\\agentrise-hook.exe"
    private let macPath = "/Users/u/Library/Application Support/Agentrise/bin/agentrise-hook"
    private let opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]

    private func json(_ obj: Any) throws -> String {
        try #require(String(data: JSONSerialization.data(withJSONObject: obj, options: opts), encoding: .utf8))
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ar 测试 \(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func claudeOnWindowsIsExecForm() throws {
        let c = HookPlan.command(hookPath: winPath, agent: .claude, platform: .windows(.exec))
        #expect(c == HookCommand(command: winPath, args: ["--agent", "claude"]))
        let file = HookPlan.claude(settings: URL(fileURLWithPath: "/x/settings.json"), platform: .windows(.exec))
        let h = try #require((file.entry(hookPath: winPath, event: "Stop")["hooks"] as? [[String: Any]])?.first)
        #expect(try json(h) == #"{"args":["--agent","claude"],"async":true,"command":"C:\\Users\\张 三\\AppData\\Local\\Agentrise\\bin\\agentrise-hook.exe","timeout":5,"type":"command"}"#)
    }

    @Test func claudeOnWindowsPowerShellFallback() throws {
        let c = HookPlan.command(hookPath: winPath, agent: .claude, platform: .windows(.powershell))
        #expect(c.command == "& 'C:\\Users\\张 三\\AppData\\Local\\Agentrise\\bin\\agentrise-hook.exe' --agent claude")
        #expect(c.shell == "powershell")
        #expect(c.args == nil && c.commandWindows == nil)
        #expect(try json(c.fields) == #"{"command":"& 'C:\\Users\\张 三\\AppData\\Local\\Agentrise\\bin\\agentrise-hook.exe' --agent claude","shell":"powershell"}"#)
    }

    @Test func codexOnWindowsUsesCommandWindows() throws {
        for shell in [WindowsHookShell.exec, .powershell] {
            let c = HookPlan.command(hookPath: winPath, agent: .codex, platform: .windows(shell))
            #expect(c.commandWindows == "& 'C:\\Users\\张 三\\AppData\\Local\\Agentrise\\bin\\agentrise-hook.exe' --agent codex")
            #expect(c.command == "\"\(winPath)\" --agent codex")
            #expect(c.args == nil && c.shell == nil)
        }
        let file = HookPlan.codex(codexHome: URL(fileURLWithPath: "/x"), platform: .windows(.exec))
        let h = try #require((file.entry(hookPath: winPath, event: "Stop")["hooks"] as? [[String: Any]])?.first)
        #expect(try json(h) == #"{"async":true,"command":"\"C:\\Users\\张 三\\AppData\\Local\\Agentrise\\bin\\agentrise-hook.exe\" --agent codex","commandWindows":"& 'C:\\Users\\张 三\\AppData\\Local\\Agentrise\\bin\\agentrise-hook.exe' --agent codex","timeout":3,"type":"command"}"#)
    }

    @Test func powerShellQuotesAreDoubled() {
        #expect(HookPlan.powerShellQuoted("C:\\Users\\O'Brien\\a b") == "'C:\\Users\\O''Brien\\a b'")
        #expect(HookPlan.powerShellQuoted("x\u{2019}y") == "'x\u{2019}\u{2019}y'")
        #expect(HookPlan.powerShellQuoted("$env:x `n") == "'$env:x `n'")   // nothing else is special in single quotes
        let c = HookPlan.command(hookPath: "C:\\Users\\O'Brien\\agentrise-hook.exe", agent: .codex, platform: .windows(.exec))
        #expect(c.commandWindows == "& 'C:\\Users\\O''Brien\\agentrise-hook.exe' --agent codex")
    }

    /// The macOS spelling is what main wrote (the recorded merge in `HookPlanTests` guards the whole file).
    @Test func posixIsUnchanged() throws {
        #expect(HookPlan.command(hookPath: macPath, agent: .claude, platform: .posix) == HookCommand(command: "\"\(macPath)\""))
        #expect(HookPlan.command(hookPath: macPath, agent: .codex, platform: .posix) == HookCommand(command: "\"\(macPath)\" --agent codex"))
        #if !os(Windows)
        #expect(HookPlatform.current == .posix)
        #expect(HookPlan.claude(home: URL(fileURLWithPath: "/h")).command(macPath) == "\"\(macPath)\"")
        #else
        #expect(HookPlatform.current == .windows(.exec))
        #endif
        let h = try #require((HookPlan.claude(settings: URL(fileURLWithPath: "/x"), platform: .posix).entry(hookPath: macPath)["hooks"] as? [[String: Any]])?.first)
        #expect(try json(h) == #"{"async":true,"command":"\"/Users/u/Library/Application Support/Agentrise/bin/agentrise-hook\"","timeout":5,"type":"command"}"#)
    }

    @Test func oursInEitherSpelling() {
        for platform in [HookPlatform.posix, .windows(.exec), .windows(.powershell)] {
            for agent in AgentKind.allCases {
                let path = platform == .posix ? macPath : winPath
                var h: [String: Any] = ["type": "command"]
                h.merge(HookPlan.command(hookPath: path, agent: agent, platform: platform).fields) { a, _ in a }
                let group: [String: Any] = ["hooks": [h]]
                #expect(HookPlan.isOurs(group), "\(platform) \(agent)")
            }
        }
        #expect(!HookPlan.isOurs(["hooks": [["type": "command", "command": "C:\\Tools\\guard.exe", "args": ["x"]]]]))
        #expect(!HookPlan.isOurs(["hooks": [["type": "command", "command": "echo bye"]]]))
        // An app-server listing may carry only the Windows command.
        #expect(HookPlan.isOurs(handler: ["commandWindows": "& '\(winPath)' --agent codex"]))
    }

    /// The Windows entries through a real merge: twice is still one entry per event, the user's hooks stay, a backup is
    /// written, and uninstalling gives back the original.
    @Test func windowsInstallIsIdempotent() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("settings.json")
        let original = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"C:\\Tools\\done.exe","args":["--x"]}]}]},"model":"opus"}"#
        try Data(original.utf8).write(to: url)
        let file = HookPlan.claude(settings: url, platform: .windows(.exec))
        let backup = try file.install(hookPath: winPath)
        #expect(backup?.lastPathComponent.hasPrefix("settings.json.agentrise-backup-") == true)
        #expect(try Data(contentsOf: try #require(backup)) == Data(original.utf8))
        _ = try file.install(hookPath: winPath)
        let out = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let hooks = try #require(out["hooks"] as? [String: [Any]])
        #expect(Set(hooks.keys) == Set(HookPlan.claudeEvents.map(\.rawValue)))
        for (ev, groups) in hooks { #expect(groups.filter(HookPlan.isOurs).count == 1, "\(ev)") }
        #expect(hooks["Stop"]?.count == 2)
        let ours = try #require((hooks["Stop"]?.first(where: HookPlan.isOurs) as? [String: Any])?["hooks"] as? [[String: Any]])
        #expect(ours.first?["args"] as? [String] == ["--agent", "claude"])
        #expect(ours.first?["command"] as? String == winPath)
        try file.uninstall()
        #expect(!file.isInstalled())
        let back = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
        #expect(back == (try JSONSerialization.jsonObject(with: Data(original.utf8)) as! NSDictionary))
    }

    @Test func claudeConfigDirHonoursEnvironment() {
        let home = URL(fileURLWithPath: "/h")
        #expect(HookPlan.claudeConfigDir(env: [:], home: home) == home.appendingPathComponent(".claude", isDirectory: true))
        #expect(HookPlan.claudeConfigDir(env: ["CLAUDE_CONFIG_DIR": ""], home: home) == home.appendingPathComponent(".claude", isDirectory: true))
        #expect(HookPlan.claudeConfigDir(env: ["CLAUDE_CONFIG_DIR": "/cfg"], home: home).lastPathComponent == "cfg")
    }
}
