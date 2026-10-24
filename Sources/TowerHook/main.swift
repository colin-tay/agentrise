import Foundation
import TowerKit

// Runs on every Claude Code hook event. It must stay invisible to Claude:
// exit 0, never print anything, give up fast if Agentrise is not running.
let input = FileHandle.standardInput.readDataToEndOfFile()
if let event = EventSlimmer.slim(rawJSON: input, env: ProcessInfo.processInfo.environment) {
    SocketClient.send(EventSlimmer.encodeLine(event), to: TowerPaths.socketPath())
}
exit(0)
