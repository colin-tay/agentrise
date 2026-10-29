// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import AgentriseScene

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

/// How the macOS app finds and starts `codex app-server` (the trust logic itself is `CodexAppServer` in AgentriseScene).
extension CodexAppServer {
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
        return try body(CodexAppServer(transport: rpc, hooksFile: HookInstaller.codex.url,
                                        cwd: FileManager.default.homeDirectoryForCurrentUser.path))
    }

    /// Runs `body` against a local app-server on a background queue and reports back on the main queue.
    static func inBackground<T>(_ body: @escaping (CodexAppServer) throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try withLocal(body) }
            DispatchQueue.main.async { done(r) }
        }
    }
}
