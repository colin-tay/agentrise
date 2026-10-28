// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation

/// One JSON-RPC request/response with `codex app-server`.
protocol RPCTransport {
    /// Sends `method` and returns the response's `result` object. Throws on a JSON-RPC error, a timeout, or a dead server.
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any]
}

enum CodexRPCError: LocalizedError, Equatable {
    case binaryNotFound, timedOut, closed, unexpectedResponse, noAgentriseHooks
    case rpc(String)
    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "找不到 codex"
        case .timedOut: return "codex app-server 没有及时回应"
        case .closed: return "codex app-server 提前退出了"
        case .unexpectedResponse: return "codex app-server 的回应看不懂"
        case .noAgentriseHooks: return "Codex 没有列出 Agentrise 的 hook"
        case .rpc(let m): return "codex app-server：\(m)"
        }
    }
}

/// `codex app-server` over stdio: one JSON object per line. Every call shares one overall deadline;
/// `close()` (also run on deinit) always ends the process.
final class StdioRPC: RPCTransport {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let cond = NSCondition()
    private var buffer = Data()
    private var lines: [Data] = []
    private var eof = false
    private let deadline: Date
    private var nextId = 1

    init(binary: URL, arguments: [String] = ["app-server"], timeout: TimeInterval = 15) throws {
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = binary
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // A GUI app's PATH is short; an npm-installed codex needs `node` next to it or in the usual places.
        let extra = [binary.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + [env["PATH"]].compactMap { $0 }).joined(separator: ":")
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A dead server must fail the write, not kill the app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] h in self?.received(h.availableData) }
        do { try process.run() } catch { output.fileHandleForReading.readabilityHandler = nil; throw error }
    }

    deinit { close() }

    /// `initialize`, then the `initialized` notification.
    func handshake(version: String) throws {
        _ = try call("initialize", ["clientInfo": ["name": "agentrise", "version": version]])
        try send(["jsonrpc": "2.0", "method": "initialized"])
    }

    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let id = nextId; nextId += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            let line = try nextLine()
            // Notifications and server requests are interleaved; only our id answers us.
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["id"] as? NSNumber)?.intValue == id, obj["method"] == nil else { continue }
            if let err = obj["error"] {
                throw CodexRPCError.rpc(((err as? [String: Any])?["message"] as? String) ?? "\(err)")
            }
            if let r = obj["result"] as? [String: Any] { return r }
            if obj["result"] is NSNull { return [:] }
            throw CodexRPCError.unexpectedResponse
        }
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let until = Date().addingTimeInterval(1)
        while process.isRunning && Date() < until { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func send(_ obj: [String: Any]) throws {
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        do { try input.fileHandleForWriting.write(contentsOf: d + Data("\n".utf8)) } catch { throw CodexRPCError.closed }
    }

    private func received(_ d: Data) {
        cond.lock()
        if d.isEmpty {
            eof = true
            output.fileHandleForReading.readabilityHandler = nil
        } else {
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer.subdata(in: buffer.startIndex..<nl))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        cond.broadcast()
        cond.unlock()
    }

    private func nextLine() throws -> Data {
        cond.lock(); defer { cond.unlock() }
        while lines.isEmpty {
            if eof { throw CodexRPCError.closed }
            if !cond.wait(until: deadline), lines.isEmpty, !eof { throw CodexRPCError.timedOut }
        }
        return lines.removeFirst()
    }
}

/// Trusts or untrusts Agentrise's hooks through `codex app-server`, the same path as Codex's own /hooks screen.
/// Never computes a hash itself and never touches anyone else's hooks or trust entries.
struct CodexAppServer {
    let transport: RPCTransport
    /// The hooks.json Agentrise writes to; trust keys look like `<its absolute path>:<event>:<group>:<hook>`.
    let hooksFile: URL
    /// The directory `hooks/list` is asked about.
    let cwd: String

    init(transport: RPCTransport, hooksFile: URL = HookInstaller.codex.url,
         cwd: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.transport = transport; self.hooksFile = hooksFile; self.cwd = cwd
    }

    /// Common install locations first (a GUI app's PATH is short), then `$PATH`.
    static func locateBinary(env: [String: String] = ProcessInfo.processInfo.environment,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        let fixed = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                     home.appendingPathComponent(".local/bin/codex").path, home.appendingPathComponent(".npm-global/bin/codex").path]
        let fromPath = (env["PATH"] ?? "").split(separator: ":").filter { !$0.isEmpty }.map { "\($0)/codex" }
        return (fixed + fromPath).first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// Starts `codex app-server`, runs `body`, and always ends the server. Blocks: call it off the main thread.
    static func withLocal<T>(timeout: TimeInterval = 15, _ body: (CodexAppServer) throws -> T) throws -> T {
        guard let bin = locateBinary() else { throw CodexRPCError.binaryNotFound }
        let rpc = try StdioRPC(binary: bin, timeout: timeout)
        defer { rpc.close() }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        try rpc.handshake(version: version)
        return try body(CodexAppServer(transport: rpc))
    }

    /// Runs `body` against a local app-server on a background queue and reports back on the main queue.
    static func inBackground<T>(_ body: @escaping (CodexAppServer) throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try withLocal(body) }
            DispatchQueue.main.async { done(r) }
        }
    }

    /// Marks every untrusted or modified Agentrise hook in our hooks.json as trusted. Returns how many were newly trusted.
    func trustAgentriseHooks() throws -> Int {
        let paths = filePaths
        let ours = try listedHooks().filter { isIn(paths, $0) && isAgentrise($0) }
        guard !ours.isEmpty else { throw CodexRPCError.noAgentriseHooks }
        var value: [String: Any] = [:]
        for h in ours {
            guard let status = h["trustStatus"] as? String, status == "untrusted" || status == "modified",
                  let key = h["key"] as? String, let hash = h["currentHash"] as? String else { continue }
            value[key] = ["trusted_hash": hash]
        }
        guard !value.isEmpty else { return 0 }
        try writeState(value, strategy: "upsert")
        return value.count
    }

    /// Drops, from the user config layer, the trust entries of our hooks.json that no longer belong to one of the
    /// user's own hooks there. Run after `HookInstaller.codex.uninstall()`. Returns how many entries were removed
    /// (0, writing nothing, when Codex reports no user layer).
    func untrustAgentriseHooks() throws -> Int {
        // Only the user's own config.toml layer is written back; the merged config may carry system or managed entries.
        let r = try transport.call("config/read", ["includeLayers": true])
        guard let user = (r["layers"] as? [[String: Any]])?.first(where: { ($0["name"] as? [String: Any])?["type"] as? String == "user" })
        else { return 0 }
        let state = ((user["config"] as? [String: Any])?["hooks"] as? [String: Any])?["state"] as? [String: Any] ?? [:]
        let paths = filePaths
        let prefixes = paths.map { $0 + ":" }
        let inOurFile = state.keys.filter { k in prefixes.contains { k.hasPrefix($0) } }
        guard !inOurFile.isEmpty else { return 0 }
        // Hooks the user keeps in the same file still need their trust.
        let usersOwn = Set(try listedHooks().filter { isIn(paths, $0) && !isAgentrise($0) }.compactMap { $0["key"] as? String })
        let drop = inOurFile.filter { !usersOwn.contains($0) }
        guard !drop.isEmpty else { return 0 }
        var keep = state
        for k in drop { keep[k] = nil }
        try writeState(keep, strategy: "replace")
        return drop.count
    }

    private func listedHooks() throws -> [[String: Any]] {
        let r = try transport.call("hooks/list", ["cwds": [cwd]])
        guard let data = r["data"] as? [[String: Any]] else { throw CodexRPCError.unexpectedResponse }
        return data.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }

    private func writeState(_ value: [String: Any], strategy: String) throws {
        _ = try transport.call("config/batchWrite", [
            "edits": [["keyPath": "hooks.state", "value": value, "mergeStrategy": strategy]],
            "reloadUserConfig": true,
        ])
    }

    /// Codex reports the file with symlinks resolved (/tmp → /private/tmp), so accept both spellings.
    private var filePaths: Set<String> {
        var s: Set<String> = [hooksFile.path, hooksFile.standardizedFileURL.path]
        if let dir = realpath(hooksFile.deletingLastPathComponent().path, nil) {
            s.insert(String(cString: dir) + "/" + hooksFile.lastPathComponent)
            free(dir)
        }
        return s
    }

    private func isIn(_ paths: Set<String>, _ h: [String: Any]) -> Bool { (h["sourcePath"] as? String).map(paths.contains) ?? false }
    private func isAgentrise(_ h: [String: Any]) -> Bool { (h["command"] as? String)?.contains(HookInstaller.marker) == true }
}
