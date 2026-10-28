// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit
@testable import AgentriseApp
@testable import Agentrise
@testable import AgentriseScene

/// A scripted app-server: answers each method from `responses` and records every call.
private final class FakeRPC: RPCTransport {
    var responses: [String: [String: Any]]
    var calls: [(method: String, params: [String: Any])] = []
    init(_ responses: [String: [String: Any]]) { self.responses = responses }
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        calls.append((method, params))
        guard let r = responses[method] else { throw CodexRPCError.rpc("no \(method)") }
        return r
    }
    var writes: [[String: Any]] { calls.filter { $0.method == "config/batchWrite" }.map(\.params) }
}

@Suite struct CodexInstallerTests {
    private let hookPath = "/Users/u/Library/Application Support/Agentrise/bin/agentrise-hook"

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agentrise-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Recorded from `HookInstaller.merged` before it was moved into `HookFile`.
    @Test func claudeInstallerUnchanged() throws {
        let golden = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-installer-merged.json"), encoding: .utf8)
        let input = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\"/old/Agentrise/bin/agentrise-hook\"","async":true,"timeout":5}]}]}}"#
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        // The static API.
        let m = try HookInstaller.merged(obj, hookPath: hookPath)
        #expect(String(data: try JSONSerialization.data(withJSONObject: m, options: opts), encoding: .utf8) == golden)

        // `HookInstaller.claude` is `HookPlan.claude` in the user's home (writing it is `HookPlanTests`).
        let c = HookInstaller.claude
        #expect(c.url == HookInstaller.settingsURL)
        #expect(c.url == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"))
        #expect(c.events == HookPlan.claudeEvents.map(\.rawValue))
        #expect(c.command(hookPath) == "\"\(hookPath)\"")
        #expect(HookInstaller.codex.url == HookInstaller.codexHome().appendingPathComponent("hooks.json"))
    }

    // MARK: - Trust through the app-server

    private let src = "/Users/u/.codex/hooks.json"
    private var ourCmd: String { "\"\(hookPath)\" --agent codex" }

    private func hook(_ key: String, _ status: String, _ cmd: String, source: String? = nil, hash: String) -> [String: Any] {
        ["key": key, "currentHash": hash, "trustStatus": status, "sourcePath": source ?? src, "command": cmd, "eventName": "stop"]
    }

    @Test func trustSelectsOnlyOurHooks() throws {
        let rpc = FakeRPC(["hooks/list": ["data": [["cwd": "/Users/u", "hooks": [
            hook("\(src):stop:1:0", "untrusted", ourCmd, hash: "sha256:a"),
            hook("\(src):pre_tool_use:0:0", "trusted", ourCmd, hash: "sha256:b"),
            hook("\(src):stop:0:0", "untrusted", "echo bye", hash: "sha256:c"),
        ]]]], "config/batchWrite": [:]])
        let server = CodexAppServer(transport: rpc, hooksFile: URL(fileURLWithPath: src), cwd: "/Users/u")
        #expect(try server.trustAgentriseHooks() == 1)

        #expect(rpc.calls.first?.method == "hooks/list")
        #expect(rpc.calls.first?.params["cwds"] as? [String] == ["/Users/u"])
        let w = try #require(rpc.writes.first)
        #expect(rpc.writes.count == 1)
        #expect(w["reloadUserConfig"] as? Bool == true)
        let edit = try #require((w["edits"] as? [[String: Any]])?.first)
        #expect(edit["keyPath"] as? String == "hooks.state")
        #expect(edit["mergeStrategy"] as? String == "upsert")
        let value = try #require(edit["value"] as? [String: [String: String]])
        #expect(value == ["\(src):stop:1:0": ["trusted_hash": "sha256:a"]])
    }

    @Test func trustModifiedAndSkipsOtherFiles() throws {
        let rpc = FakeRPC(["hooks/list": ["data": [["hooks": [
            hook("\(src):stop:1:0", "modified", ourCmd, hash: "sha256:new"),
            hook("/work/.codex/hooks.json:stop:0:0", "untrusted", ourCmd, source: "/work/.codex/hooks.json", hash: "sha256:x"),
        ]]]], "config/batchWrite": [:]])
        let server = CodexAppServer(transport: rpc, hooksFile: URL(fileURLWithPath: src), cwd: "/Users/u")
        #expect(try server.trustAgentriseHooks() == 1)
        let value = (rpc.writes.first?["edits"] as? [[String: Any]])?.first?["value"] as? [String: [String: String]]
        #expect(value == ["\(src):stop:1:0": ["trusted_hash": "sha256:new"]])
    }

    @Test func trustWithEverythingTrustedWritesNothing() throws {
        let rpc = FakeRPC(["hooks/list": ["data": [["hooks": [hook("\(src):stop:1:0", "trusted", ourCmd, hash: "sha256:a")]]]]])
        let server = CodexAppServer(transport: rpc, hooksFile: URL(fileURLWithPath: src), cwd: "/Users/u")
        #expect(try server.trustAgentriseHooks() == 0)
        #expect(rpc.writes.isEmpty)
    }

    @Test func trustThrowsWhenCodexListsNoneOfOurs() {
        let rpc = FakeRPC(["hooks/list": ["data": [["hooks": [hook("\(src):stop:0:0", "untrusted", "echo bye", hash: "sha256:c")]]]]])
        let server = CodexAppServer(transport: rpc, hooksFile: URL(fileURLWithPath: src), cwd: "/Users/u")
        #expect(throws: CodexRPCError.self) { try server.trustAgentriseHooks() }
        #expect(rpc.writes.isEmpty)
    }

    /// `config/read {includeLayers: true}`: the merged `config` plus one entry per layer.
    private func layered(merged: Any, user: Any?, system: Any? = nil) -> [String: Any] {
        var layers: [[String: Any]] = []
        if let user { layers.append(["name": ["type": "user", "file": "/Users/u/.codex/config.toml", "profile": NSNull()], "config": ["hooks": ["state": user]]]) }
        if let system { layers.append(["name": ["type": "system", "file": "/etc/codex/config.toml"], "config": ["hooks": ["state": system]]]) }
        return ["config": ["model": "x", "hooks": ["state": merged]], "layers": layers]
    }

    @Test func untrustKeepsOthers() throws {
        let other = "/work/.codex/hooks.json:stop:0:0"
        let state: [String: Any] = [
            "\(src):stop:1:0": ["trusted_hash": "sha256:a"],
            "\(src):pre_tool_use:0:0": ["trusted_hash": "sha256:b"],
            other: ["trusted_hash": "sha256:o"],
        ]
        let rpc = FakeRPC([
            "config/read": layered(merged: state, user: state),
            "hooks/list": ["data": [["hooks": []]]],
            "config/batchWrite": [:],
        ])
        let server = CodexAppServer(transport: rpc, hooksFile: URL(fileURLWithPath: src), cwd: "/Users/u")
        #expect(try server.untrustAgentriseHooks() == 2)
        #expect(rpc.calls.first { $0.method == "config/read" }?.params["includeLayers"] as? Bool == true)
        let w = try #require(rpc.writes.first)
        #expect(rpc.writes.count == 1)
        #expect(w["reloadUserConfig"] as? Bool == true)
        let edit = try #require((w["edits"] as? [[String: Any]])?.first)
        #expect(edit["keyPath"] as? String == "hooks.state")
        #expect(edit["mergeStrategy"] as? String == "replace")
        #expect(edit["value"] as? [String: [String: String]] == [other: ["trusted_hash": "sha256:o"]])
    }

    /// The user's own hooks in the same hooks.json keep their trust.
    @Test func untrustKeepsUserHooksInSameFile() throws {
        let state: [String: Any] = [
            "\(src):stop:0:0": ["trusted_hash": "sha256:user"],
            "\(src):stop:1:0": ["trusted_hash": "sha256:a"],
        ]
        let rpc = FakeRPC([
            "config/read": layered(merged: state, user: state),
            "hooks/list": ["data": [["hooks": [hook("\(src):stop:0:0", "trusted", "echo bye", hash: "sha256:user")]]]],
            "config/batchWrite": [:],
        ])
        let server = CodexAppServer(transport: rpc, hooksFile: URL(fileURLWithPath: src), cwd: "/Users/u")
        #expect(try server.untrustAgentriseHooks() == 1)
        let edit = (rpc.writes.first?["edits"] as? [[String: Any]])?.first
        #expect(edit?["value"] as? [String: [String: String]] == ["\(src):stop:0:0": ["trusted_hash": "sha256:user"]])
    }

    /// Only the user layer is written back: a system layer's trust must not be copied into the user's config.toml.
    @Test func untrustWritesBackOnlyTheUserLayer() throws {
        let sys = "/etc/codex/hooks.json:stop:0:0"
        let user: [String: Any] = ["\(src):stop:1:0": ["trusted_hash": "sha256:a"], "/w/hooks.json:stop:0:0": ["trusted_hash": "sha256:w"]]
        var merged = user
        merged[sys] = ["trusted_hash": "sha256:s"]
        let rpc = FakeRPC([
            "config/read": layered(merged: merged, user: user, system: [sys: ["trusted_hash": "sha256:s"]]),
            "hooks/list": ["data": [["hooks": []]]],
            "config/batchWrite": [:],
        ])
        let server = CodexAppServer(transport: rpc, hooksFile: URL(fileURLWithPath: src), cwd: "/Users/u")
        #expect(try server.untrustAgentriseHooks() == 1)
        let edit = (rpc.writes.first?["edits"] as? [[String: Any]])?.first
        #expect(edit?["mergeStrategy"] as? String == "replace")
        #expect(edit?["value"] as? [String: [String: String]] == ["/w/hooks.json:stop:0:0": ["trusted_hash": "sha256:w"]])
    }

    /// A user layer without any hooks.state counts as empty.
    @Test func untrustWithUserLayerMissingStateWritesNothing() throws {
        let rpc = FakeRPC([
            "config/read": ["config": ["hooks": ["state": ["\(src):stop:1:0": ["trusted_hash": "sha256:a"]]]],
                            "layers": [["name": ["type": "user", "file": "/Users/u/.codex/config.toml"], "config": ["model": "x"]]]],
            "hooks/list": ["data": [["hooks": []]]],
            "config/batchWrite": [:],
        ])
        let server = CodexAppServer(transport: rpc, hooksFile: URL(fileURLWithPath: src), cwd: "/Users/u")
        #expect(try server.untrustAgentriseHooks() == 0)
        #expect(rpc.writes.isEmpty)
    }

    @Test func untrustWithoutUserLayerWritesNothing() throws {
        let rpc = FakeRPC([
            "config/read": layered(merged: ["\(src):stop:1:0": ["trusted_hash": "sha256:a"]], user: nil,
                                   system: ["\(src):stop:1:0": ["trusted_hash": "sha256:a"]]),
            "hooks/list": ["data": [["hooks": []]]],
            "config/batchWrite": [:],
        ])
        let server = CodexAppServer(transport: rpc, hooksFile: URL(fileURLWithPath: src), cwd: "/Users/u")
        #expect(try server.untrustAgentriseHooks() == 0)
        #expect(rpc.writes.isEmpty)
    }

    @Test func untrustWithNothingOfOursWritesNothing() throws {
        let rpc = FakeRPC(["config/read": layered(merged: NSNull(), user: NSNull()), "hooks/list": ["data": []]])
        let server = CodexAppServer(transport: rpc, hooksFile: URL(fileURLWithPath: src), cwd: "/Users/u")
        #expect(try server.untrustAgentriseHooks() == 0)
        #expect(rpc.writes.isEmpty)
    }

    @Test func codexHomeHonoursEnvironment() {
        #expect(HookInstaller.codexHome(env: ["CODEX_HOME": "/tmp/cx"]).path == "/tmp/cx")
        #expect(HookInstaller.codexHome(env: ["CODEX_HOME": ""]).path.hasSuffix("/.codex"))
        #expect(HookInstaller.codexHome(env: [:]) == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    }

    // MARK: - Locating codex and talking to it

    @Test func locateBinaryPrefersCommonPlacesThenPath() {
        let home = URL(fileURLWithPath: "/Users/u")
        #expect(CodexAppServer.locateBinary(env: ["PATH": "/a:/b"], home: home, isExecutable: { $0 == "/b/codex" })?.path == "/b/codex")
        #expect(CodexAppServer.locateBinary(env: ["PATH": "/b"], home: home,
                                            isExecutable: { $0 == "/b/codex" || $0 == "/Users/u/.local/bin/codex" })?.path == "/Users/u/.local/bin/codex")
        #expect(CodexAppServer.locateBinary(env: [:], home: home, isExecutable: { _ in false }) == nil)
    }

    private func script(_ body: String) throws -> URL {
        let url = try tempDir().appendingPathComponent("fake-codex")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        chmod(url.path, 0o755)
        return url
    }

    /// Answers every request with its own id after a notification; `fail` gets a JSON-RPC error.
    private let echoServer = #"""
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      [ -z "$id" ] && continue
      echo '{"jsonrpc":"2.0","method":"remoteControl/status/changed","params":{}}'
      case "$line" in
        *'"method":"fail"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-1,\"message\":\"nope\"}}" ;;
        *) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"echo\":$id}}" ;;
      esac
    done
    """#

    @Test func stdioMatchesResponsesById() throws {
        let rpc = try StdioRPC(binary: try script(echoServer), timeout: 5)
        defer { rpc.close() }
        try rpc.handshake(version: "test")
        #expect(try rpc.call("hooks/list", [:])["echo"] as? Int == 2)
        #expect(throws: CodexRPCError.rpc("nope")) { try rpc.call("fail", [:]) }
        #expect(try rpc.call("config/read", [:])["echo"] as? Int == 4)
    }

    @Test func stdioTimesOutAndEndsTheServer() throws {
        let rpc = try StdioRPC(binary: try script("exec sleep 30\n"), timeout: 0.5)
        let start = Date()
        #expect(throws: CodexRPCError.timedOut) { try rpc.call("hooks/list", [:]) }
        #expect(Date().timeIntervalSince(start) < 3)
        rpc.close()
    }

    @Test func stdioReportsAServerThatExits() throws {
        let rpc = try StdioRPC(binary: try script("exit 0\n"), timeout: 5)
        defer { rpc.close() }
        #expect(throws: CodexRPCError.self) { try rpc.call("hooks/list", [:]) }
    }

    /// Through `UserDefaults` (the Mac's settings store), under the key Settings' `@AppStorage` reads.
    @Test func firstCodexEventMarksCodexSeen() throws {
        let name = "agentrise-test-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        HookPlan.noteEvent(from: nil, settings: d)
        HookPlan.noteEvent(from: .claude, settings: d)
        #expect(d.bool(forKey: HookPlan.codexSeenKey) == false)
        HookPlan.noteEvent(from: .codex, settings: d)
        #expect(d.bool(forKey: "codexSeen") == true)
    }
}
