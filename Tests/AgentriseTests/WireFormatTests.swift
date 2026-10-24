import Foundation
import Testing
import TowerKit
@testable import Agentrise

@Suite struct WireFormatTests {
    private let oldLine = Data("""
    {"event":"Stop","sessionId":"s1","cwd":"/work","lastAssistantMessage":"done","receivedAt":1800000000}
    """.utf8)

    @Test func oldLineWithoutAgentDecodesAsClaude() throws {
        let e = try #require(EventSlimmer.decodeLine(oldLine))
        #expect(e.agent == nil)
        #expect(e.agentPid == nil)
        #expect(e.sessionId == "s1")
        #expect(Adapters.adapter(for: e.agent) == ClaudeAdapter.self)
        #expect(Adapters.adapter(for: nil) == ClaudeAdapter.self)
    }

    @Test func claudeSlimLeavesAgentNil() throws {
        let raw = Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8)
        let e = try #require(EventSlimmer.slim(rawJSON: raw, env: [:], agent: .claude))
        #expect(e.agent == nil)
        let d = try #require(EventSlimmer.slim(rawJSON: raw, env: [:]))
        #expect(d.agent == nil)
        let line = String(decoding: EventSlimmer.encodeLine(d), as: UTF8.self)
        #expect(!line.contains("\"agent\""))
        #expect(!line.contains("agentPid"))
    }

    @Test func codexSlimTagsTheEventAndRoundTrips() throws {
        let raw = Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8)
        var e = try #require(EventSlimmer.slim(rawJSON: raw, env: [:], agent: .codex))
        #expect(e.agent == .codex)
        e.agentPid = 4242
        let back = try #require(EventSlimmer.decodeLine(EventSlimmer.encodeLine(e)))
        #expect(back.agent == .codex)
        #expect(back.agentPid == 4242)
        #expect(AgentKind.claude.processName == "claude")
        #expect(AgentKind.codex.processName == "codex")
    }

    @Test func newHookEventNamesParse() throws {
        for (name, ev) in [("PermissionRequest", HookEventName.permissionRequest),
                           ("Interrupt", .interrupt), ("PostCompact", .postCompact)] {
            let raw = Data(#"{"hook_event_name":"\#(name)","session_id":"s1"}"#.utf8)
            #expect(EventSlimmer.slim(rawJSON: raw, env: [:], agent: .codex)?.event == ev)
        }
    }

    @Test func claudeInstallerNeverAddsPermissionRequest() throws {
        let out = try HookInstaller.merged([:], hookPath: "/x")
        let hooks = try #require(out["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookInstaller.claudeEvents.map(\.rawValue)))
        #expect(HookInstaller.claudeEvents.count == 12)
        for n in ["PermissionRequest", "Interrupt", "PostCompact"] { #expect(hooks[n] == nil) }
        let group = try #require((hooks["Stop"] as? [Any])?.first as? [String: Any])
        let cmd = try #require((group["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        #expect(cmd == "\"/x\"")
    }

    @Test func ancestryIncludesTheStartingProcess() {
        let me = String(ProcessInfo.processInfo.processName.prefix(15))
        #expect(ProcessAncestry.ancestor(named: me, from: getpid()) == getpid())
        #expect(ProcessAncestry.ancestor(named: "no-such-process", from: getpid()) == nil)
    }

    @Test func argumentsAreReadFromTheKernel() throws {
        let args = try #require(ProcessAncestry.arguments(of: getpid()))
        #expect(args == CommandLine.arguments)
        #expect(ProcessAncestry.arguments(of: 999_999) == nil)
    }

    @Test func codexSharedDaemonIsNotTheSessionsProcess() throws {
        // A stand-in "codex" process: a copy of sh named codex, once plain and once as the TUI's shared daemon.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-pid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("codex")
        try FileManager.default.copyItem(atPath: "/bin/sh", toPath: bin.path)
        var started: [Process] = []
        var keepOpen: [Pipe] = []
        defer { for p in started { p.terminate() }; for pipe in keepOpen { try? pipe.fileHandleForWriting.close() } }
        // `read` blocks on an open pipe and is a shell builtin: no grandchild process can outlive the stand-in.
        func run(_ args: [String]) -> Process? {
            let p = Process(); p.executableURL = bin; p.arguments = args
            let pipe = Pipe(); p.standardInput = pipe
            do { try p.run() } catch { return nil }
            started.append(p); keepOpen.append(pipe)
            return p
        }
        guard let plain = run(["-c", "read x; :"]),
              let daemon = run(["-c", "read x; :", "codex", "app-server", "--listen", "unix://", "--managed-daemon"]) else {
            // Some systems refuse to launch a copied system binary; nothing to verify then.
            print("skipped: could not launch the copied sh")
            return
        }
        usleep(200_000)
        guard plain.isRunning, daemon.isRunning else {
            print("skipped: the copied sh was killed on launch")
            return
        }
        #expect(ProcessAncestry.agentPid(for: .codex, from: plain.processIdentifier) == plain.processIdentifier)
        #expect(ProcessAncestry.agentPid(for: .codex, from: daemon.processIdentifier) == nil)
        #expect(ProcessAncestry.arguments(of: daemon.processIdentifier)?.last == "--managed-daemon")
    }
}
