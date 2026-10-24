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
if var event = EventSlimmer.slim(rawJSON: input, env: ProcessInfo.processInfo.environment, agent: agent) {
    event.agentPid = ProcessAncestry.ancestor(named: agent.processName, from: getppid())
    SocketClient.send(EventSlimmer.encodeLine(event), to: TowerPaths.socketPath())
    if agent == .codex, event.event == .stop || event.event == .subagentStop {
        print("{}")
    }
}
exit(0)
