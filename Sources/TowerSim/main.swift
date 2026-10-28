// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit

// Sends fake hook events to a running Agentrise.
//   agentrise-sim story          the mockup story
//   agentrise-sim load [bosses] [subs] [seconds]
let sock = TowerPaths.socketPath()
func send(_ e: SlimEvent) { SocketClient.send(EventSlimmer.encodeLine(e), to: sock) }
func ev(_ name: HookEventName, _ sid: String, _ f: (inout SlimEvent) -> Void = { _ in }) {
    var e = SlimEvent(event: name, sessionId: sid)
    e.entrypoint = "cli"; e.cwd = "/tmp/\(sid)"
    f(&e); send(e)
}
func tool(_ sid: String, _ name: String, agent: String? = nil, cmd: String? = nil, bg: Bool? = nil) {
    ev(.preToolUse, sid) { $0.toolName = name; $0.agentId = agent; $0.command = cmd; $0.runInBackground = bg; $0.toolUseId = UUID().uuidString }
}
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "story"
if mode == "story" {
    let a = "sim-boss", b = "sim-wait", c = "sim-done", d = "sim-fail"
    ev(.sessionStart, a) { $0.model = "claude-fable-5-1"; $0.sessionTitle = "重构登录模块（模拟）"; $0.source = "startup" }
    ev(.sessionStart, b) { $0.model = "claude-sonnet-5-5"; $0.sessionTitle = "整理接口文档（模拟）"; $0.source = "startup" }
    ev(.sessionStart, c) { $0.model = "claude-haiku-5-5"; $0.sessionTitle = "修复分页 bug（模拟）"; $0.source = "startup" }
    ev(.sessionStart, d) { $0.model = "claude-opus-5-5"; $0.sessionTitle = "调研缓存方案（模拟）"; $0.source = "startup" }
    for s in [a, b, c, d] { ev(.userPromptSubmit, s) }
    tool(a, "Agent")
    for i in 1...3 { ev(.subagentStart, a) { $0.agentId = "sub\(i)"; $0.agentType = "T3-17\(["a","b","c"][i-1])" } }
    Thread.sleep(forTimeInterval: TimeInterval(2))
    tool(a, "Read", agent: "sub1"); tool(a, "Bash", agent: "sub2", cmd: "npm test"); tool(a, "WebSearch", agent: "sub3")
    tool(a, "Edit")
    tool(a, "Bash", cmd: "npm run build -- --watch", bg: true)
    tool(b, "Grep"); tool(c, "Write"); tool(d, "TodoWrite")
    Thread.sleep(forTimeInterval: TimeInterval(3))
    ev(.stop, b) { $0.lastAssistantMessage = "接口文档整理好了。要不要把内部接口也写进去？" }
    tool(c, "Bash", cmd: "npm test")
    Thread.sleep(forTimeInterval: TimeInterval(2))
    ev(.stop, c) { $0.lastAssistantMessage = "已完成全部修改，测试通过。" }
    tool(d, "WebFetch")
    Thread.sleep(forTimeInterval: TimeInterval(3))
    ev(.subagentStop, a) { $0.agentId = "sub1"; $0.lastAssistantMessage = "读完了" }
    tool(d, "Bash", cmd: "rm -rf /nope"); ev(.postToolUseFailure, d) { $0.toolName = "Bash"; $0.error = "exit 1" }
    Thread.sleep(forTimeInterval: TimeInterval(3))
    ev(.subagentStop, a) { $0.agentId = "sub2"; $0.lastAssistantMessage = "" }
    Thread.sleep(forTimeInterval: TimeInterval(20))
    for s in [a, b, c, d] { ev(.sessionEnd, s) }
    print("story done")
} else {
    let bosses = args.count > 2 ? Int(args[2])! : 8
    let subs = args.count > 3 ? Int(args[3])! : 30
    let seconds = args.count > 4 ? Double(args[4])! : 120
    let models = ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    let tools = ["Read", "Grep", "Edit", "Bash", "WebSearch", "TodoWrite", "Write", "Glob"]
    for i in 0..<bosses {
        ev(.sessionStart, "load\(i)") { $0.model = models[i % 4]; $0.sessionTitle = "压测会话 \(i + 1)"; $0.source = "startup" }
        ev(.userPromptSubmit, "load\(i)")
    }
    for j in 0..<subs { ev(.subagentStart, "load\(j % bosses)") { $0.agentId = "ls\(j)"; $0.agentType = "worker\(j)" } }
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        let i = Int.random(in: 0..<bosses)
        if Bool.random() { tool("load\(i)", tools.randomElement()!) }
        else { tool("load\(i)", tools.randomElement()!, agent: "ls\(Int.random(in: 0..<subs) / bosses * bosses + i)") }
        Thread.sleep(forTimeInterval: TimeInterval(UInt32(1_000_000 * Double(bosses) / Double(bosses) / 3)) / 1_000_000)
    }
    for i in 0..<bosses { ev(.sessionEnd, "load\(i)") }
    print("load done")
}
