// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Agentrise

/// One JSON-RPC request/response with `codex app-server`.
package protocol RPCTransport {
    /// Sends `method` and returns the response's `result` object. Throws on a JSON-RPC error, a timeout, or a dead server.
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any]
}

package enum CodexRPCError: LocalizedError, Equatable {
    case binaryNotFound, timedOut, closed, unexpectedResponse, noAgentriseHooks
    case rpc(String)
    package var errorDescription: String? {
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

/// Trusts or untrusts Agentrise's hooks through `codex app-server`, the same path as Codex's own /hooks screen.
/// Never computes a hash itself and never touches anyone else's hooks or trust entries. Each platform starts the
/// server its own way (macOS: `StdioRPC` in the app; Windows: `CodexProcess` in AgentriseWin).
package struct CodexAppServer {
    package let transport: RPCTransport
    /// The hooks.json Agentrise writes to; trust keys look like `<its absolute path>:<event>:<group>:<hook>`.
    package let hooksFile: URL
    /// The directory `hooks/list` is asked about.
    package let cwd: String

    package init(transport: RPCTransport, hooksFile: URL, cwd: String) {
        self.transport = transport; self.hooksFile = hooksFile; self.cwd = cwd
    }

    /// Marks every untrusted or modified Agentrise hook in our hooks.json as trusted. Returns how many were newly trusted.
    package func trustAgentriseHooks() throws -> Int {
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
    /// user's own hooks there. Run after uninstalling the hooks (`HookFile.uninstall()`). Returns how many entries were removed
    /// (0, writing nothing, when Codex reports no user layer).
    package func untrustAgentriseHooks() throws -> Int {
        // Only the user's own config.toml layer is written back; the merged config may carry system or managed entries.
        let r = try transport.call("config/read", ["includeLayers": true])
        guard let user = (r["layers"] as? [[String: Any]])?.first(where: { ($0["name"] as? [String: Any])?["type"] as? String == "user" })
        else { return 0 }
        let state = ((user["config"] as? [String: Any])?["hooks"] as? [String: Any])?["state"] as? [String: Any] ?? [:]
        let paths = filePaths
        let prefixes = paths.map { $0 + ":" }
        let inOurFile = state.keys.filter { hasPrefix($0, prefixes) }
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

    #if os(Windows)
    /// Codex reports the file as `source_path.display()`: `C:\Users\u\.codex\hooks.json` (facts §4). Windows paths
    /// are case-insensitive, so the set holds lowercased spellings (`isIn` lowercases too). If Codex canonicalises
    /// the path (`std::fs::canonicalize`: `\\?\C:\…`, 8.3 names expanded, links followed), the canonical form matches
    /// too, with and without the `\\?\` prefix (unverified which Codex reports: the author's trial checks it).
    private var filePaths: Set<String> {
        let native = SafeFile.nativePath(of: hooksFile)
        var all = [native, native.replacingOccurrences(of: "\\", with: "/"), hooksFile.path]
        if let canonical = SafeFile.finalPath(of: hooksFile) {
            all += [canonical, canonical.hasPrefix("\\\\") ? "\\\\?\\UNC\\" + canonical.dropFirst(2) : "\\\\?\\" + canonical]
        }
        return Set(all.map { $0.lowercased() })
    }

    private func isIn(_ paths: Set<String>, _ h: [String: Any]) -> Bool {
        (h["sourcePath"] as? String).map { paths.contains($0.lowercased()) } ?? false
    }

    private func hasPrefix(_ key: String, _ prefixes: [String]) -> Bool { prefixes.contains { key.lowercased().hasPrefix($0) } }
    #else
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

    private func hasPrefix(_ key: String, _ prefixes: [String]) -> Bool { prefixes.contains { key.hasPrefix($0) } }
    #endif

    /// A listed hook that runs Agentrise's helper (its `command`, or on Windows possibly `commandWindows`).
    private func isAgentrise(_ h: [String: Any]) -> Bool { HookPlan.isOurs(handler: h) }
}
