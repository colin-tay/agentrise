// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit

// Runs on every agent hook event. It must stay invisible to the agent:
// exit 0, print nothing (except `{}` to Codex on stop events, which it reads as
// "no decision"), give up fast if Agentrise is not running.
var agent = AgentKind.claude
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--agent") {
    guard i + 1 < args.count, let kind = AgentKind(rawValue: args[i + 1]) else { exit(0) }
    agent = kind
}

let input = FileHandle.standardInput.readDataToEndOfFile()
// Codex reads `{}` on stop events as "no decision"; decided from the raw event name so a payload we
// cannot slim (or a dead socket) never leaves it without an answer.
var answersCodex = false
if agent == .codex, let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
   let name = obj["hook_event_name"] as? String, name == HookEventName.stop.rawValue || name == HookEventName.subagentStop.rawValue {
    answersCodex = true
}
if var event = EventSlimmer.slim(rawJSON: input, env: ProcessInfo.processInfo.environment, agent: agent) {
    event.agentPid = ProcessAncestry.agentPid(for: agent, from: getppid())
    SocketClient.send(EventSlimmer.encodeLine(event), to: TowerPaths.socketPath())
}
if answersCodex { print("{}") }
exit(0)
