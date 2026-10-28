// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit

/// Anchors `Bundle(for:)` to this test image.
private final class BundleMarker {}

#if os(Windows)
private let hookName = "agentrise-hook.exe"
#else
private let hookName = "agentrise-hook"
#endif

/// `isExecutableFile` on Windows depends on the file extension rules of Foundation's port; the name
/// already ends in `.exe`, so existence is enough there.
private func isRunnable(_ path: String) -> Bool {
    #if os(Windows)
    FileManager.default.fileExists(atPath: path)
    #else
    FileManager.default.isExecutableFile(atPath: path)
    #endif
}

/// The built `agentrise-hook`: `AGENTRISE_HOOK_BIN` if set, else the build directory this test image
/// was loaded from (what `swift build --show-bin-path` prints).
private func hookBinary() throws -> URL {
    if let bin = ProcessInfo.processInfo.environment["AGENTRISE_HOOK_BIN"], !bin.isEmpty {
        guard isRunnable(bin) else {
            throw HookTestError("AGENTRISE_HOOK_BIN=\(bin) is not an executable file")
        }
        return URL(fileURLWithPath: bin)
    }
    // macOS: <bin>/AgentrisePackageTests.xctest; Windows: <bin>/AgentrisePackageTests.xctest is the
    // executable itself. Walk up a few levels from both to stay independent of the bundle layout.
    var starts = [Bundle(for: BundleMarker.self).bundleURL]
    if let exe = Bundle.main.executableURL { starts.append(exe) }
    for start in starts {
        var dir = start.deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent(hookName)
            if isRunnable(candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
    }
    throw HookTestError("\(hookName) not found next to the test bundle; run `swift build` first "
                        + "(or set AGENTRISE_HOOK_BIN)")
}

private struct HookTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The environment for the child hook, pointing its data directory at `dir`.
private func childEnvironment(dataRoot dir: String) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    #if os(Windows)
    // Windows variable names are case-insensitive; drop any spelling before setting ours.
    for key in env.keys where key.uppercased() == "LOCALAPPDATA" { env.removeValue(forKey: key) }
    env["LOCALAPPDATA"] = dir
    #else
    // macOS: `homeDirectoryForCurrentUser` (what `TowerPaths` uses) ignores `HOME` and reads the
    // user database; CoreFoundation's `CFFIXED_USER_HOME` overrides it. `HOME` is set as well so
    // anything else in the child agrees. The hook's own path logic is untouched.
    env["CFFIXED_USER_HOME"] = dir
    env["HOME"] = dir
    #endif
    return env
}

/// Where the hook will send, given the environment it runs with.
private func socketPath(for env: [String: String], dataRoot dir: String) -> String {
    #if os(Windows)
    TowerPaths.socketPath(environment: env)
    #else
    TowerPaths.socketPath(home: URL(fileURLWithPath: dir, isDirectory: true))
    #endif
}

private struct HookRun {
    var status: Int32
    var stdout: String
    var elapsed: TimeInterval
}

/// Runs the hook with `stdin`; kills it if it outlives `limit` so a hang fails instead of stalling.
private func runHook(_ args: [String], stdin: Data, env: [String: String],
                     limit: TimeInterval = 10) throws -> HookRun {
    let p = Process()
    p.executableURL = try hookBinary()
    p.arguments = args
    p.environment = env
    let input = Pipe(), output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    let start = Date()
    try p.run()
    input.fileHandleForWriting.write(stdin)
    try input.fileHandleForWriting.close()
    let deadline = start.addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    let elapsed = Date().timeIntervalSince(start)
    let out = output.fileHandleForReading.readDataToEndOfFile()
    return HookRun(status: p.terminationStatus, stdout: String(decoding: out, as: UTF8.self), elapsed: elapsed)
}

private func codexStopFixture() throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/codex/stop.json")
    return try Data(contentsOf: url)
}

private let claudeStop = Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8)

/// Runs the real `agentrise-hook` against a real `SocketServer`, with the hook's data directory
/// moved into a fresh temporary one (`CFFIXED_USER_HOME` + `HOME` on macOS, `LOCALAPPDATA` on
/// Windows). The no-listener run happens only after delivery to the temp server has proven that this
/// exact environment routes the hook to the temp root. Accepted residual risk: if a future OS stopped
/// honoring `CFFIXED_USER_HOME`, each delivery test would write one line to the real socket and then
/// fail visibly (its temp server receives nothing).
@Suite(.serialized) struct HookEndToEndTests {
    /// Sends `stdin` through the hook to a listening server and checks the one line that arrives
    /// matches what `EventSlimmer` makes of the same input and environment. With `thenWithoutListener`,
    /// it then stops the server and runs the hook again in the same, now proven, environment.
    private func deliver(_ stdin: Data, args: [String], agent: AgentKind,
                         thenWithoutListener: Bool = false) async throws -> HookRun {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let env = childEnvironment(dataRoot: dir)
        let box = LineBox()
        let server = try SocketServer(path: socketPath(for: env, dataRoot: dir)) { box.add($0) }
        defer { server.stop() }

        let before = Date()
        let run = try runHook(args, stdin: stdin, env: env)
        let lines = await box.wait(for: 1)
        try? await Task.sleep(nanoseconds: 100_000_000)   // room for an unexpected second line
        #expect(box.snapshot.count == 1)
        #expect(run.status == 0)

        let expected = try #require(EventSlimmer.slim(rawJSON: stdin, env: env, agent: agent))
        var got = try #require(lines.first.flatMap(EventSlimmer.decodeLine))
        // `agentPid` depends on whatever launched the test; `receivedAt` is the hook's own clock,
        // so it is checked against the run's time window and then taken from the expected value.
        got.agentPid = nil
        #expect(got.receivedAt >= before.addingTimeInterval(-1))
        #expect(got.receivedAt <= Date().addingTimeInterval(1))
        got.receivedAt = expected.receivedAt
        #expect(got == expected)

        if thenWithoutListener {
            // Reached only once the line arrived on the temp server (the `#require` above).
            server.stop()
            let again = try runHook(args, stdin: stdin, env: env)
            #expect(again.status == 0)
            // Bounds "returns promptly": margin over the 200 ms connect timeout plus process spawn
            // (Windows Defender may scan a freshly built exe on first launch).
            #expect(again.elapsed < 5)
        }
        return run
    }

    @Test func claudeEventReachesTheServer() async throws {
        let run = try await deliver(claudeStop, args: [], agent: .claude, thenWithoutListener: true)
        #expect(run.stdout.isEmpty)
    }

    @Test func codexStopReachesTheServerAndAnswersCodex() async throws {
        let run = try await deliver(try codexStopFixture(), args: ["--agent", "codex"], agent: .codex)
        #expect(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
    }
}
