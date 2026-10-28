// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if os(Windows)
import WinSDK
#endif

/// Which models are which rank, and what each rank is called. The art of the four ranks is fixed;
/// only the names and the model keywords are the user's to change (`ranks.json`).
package struct RankBook: Codable, Equatable {
    /// Key = `Rank.rawValue`. Empty or missing → the default name.
    var names: [String: String]
    /// Key = `Rank.rawValue`. Case-insensitive substrings of the model name. Missing → the default keywords.
    var keywords: [String: [String]]

    init(names: [String: String], keywords: [String: [String]]) { self.names = names; self.keywords = keywords }

    /// A hand-edited file may carry only one of the two; the other keeps its defaults.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        keywords = try c.decodeIfPresent([String: [String]].self, forKey: .keywords) ?? [:]
    }

    static let defaults = RankBook(
        names: [Rank.seniorDirector.rawValue: "资深总监", Rank.seniorExpert.rawValue: "高级专家",
                Rank.seniorEngineer.rawValue: "高级工程师", Rank.newGrad.rawValue: "校招生"],
        keywords: [Rank.seniorDirector.rawValue: ["fable"], Rank.seniorExpert.rawValue: ["opus"],
                   Rank.newGrad.rawValue: ["haiku"], Rank.seniorEngineer.rawValue: []])

    /// Starts as `.defaults`; only the app loads the file into it (and Settings updates it),
    /// so nothing else depends on what is on this machine's disk.
    package static var current: RankBook {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage = RankBook.defaults

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Agentrise/ranks.json")

    /// A missing or unreadable file gives the defaults.
    package static func load(from url: URL = fileURL) -> RankBook {
        guard let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(RankBook.self, from: d) else { return .defaults }
        return b
    }

    package func save(to url: URL = RankBook.fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        #if os(Windows)
        try writeAtomicallyRetryingSharingViolation(enc.encode(self), to: url)
        #else
        try enc.encode(self).write(to: url, options: .atomic)
        #endif
    }

    /// Order: director → expert → new grad → everything else is a senior engineer.
    func rank(for model: String?) -> Rank {
        let m = (model ?? "").lowercased()
        for r in [Rank.seniorDirector, .seniorExpert, .newGrad] where keywordList(r).contains(where: { m.contains($0) }) { return r }
        return .seniorEngineer
    }

    package func title(_ r: Rank) -> String {
        let n = names[r.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? (Self.defaults.names[r.rawValue] ?? r.rawValue) : n
    }

    /// The keywords as typed in Settings: comma-separated.
    package func keywordText(_ r: Rank) -> String { (keywords[r.rawValue] ?? Self.defaults.keywords[r.rawValue] ?? []).joined(separator: ", ") }

    package mutating func set(_ r: Rank, name: String, keywordText: String) {
        names[r.rawValue] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        keywords[r.rawValue] = keywordText.split(whereSeparator: { ",，".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Lowercased, trimmed, never empty (an empty keyword would match every model).
    private func keywordList(_ r: Rank) -> [String] {
        (keywords[r.rawValue] ?? Self.defaults.keywords[r.rawValue] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }
}

extension Rank {
    /// The order Settings lists the ranks in.
    package static let ranksTopDown: [Rank] = [.seniorDirector, .seniorExpert, .seniorEngineer, .newGrad]
}

#if os(Windows)
/// Foundation's atomic write on Windows closes a temporary file and then `MoveFileExW`s it over the
/// destination. Antivirus or the search indexer can briefly open that just-closed file without
/// `FILE_SHARE_DELETE`, and the move then fails with `ERROR_SHARING_VIOLATION` (32). That is
/// transient, so retry a few times with short, growing pauses; any other error is thrown at once.
private func writeAtomicallyRetryingSharingViolation(_ data: Data, to url: URL) throws {
    var pauseMs: UInt32 = 50
    for attempt in 1...5 {
        do {
            return try data.write(to: url, options: .atomic)
        } catch let error as CocoaError where attempt < 5 && isSharingViolation(error) {
            Sleep(pauseMs)
            pauseMs *= 2
        }
    }
}

/// Foundation reports a failed move as `fileWriteNoPermission` with an internal `Win32Error` underneath;
/// that type is not public and does not bridge its code to `NSError`, so its `code` is read by reflection.
private func isSharingViolation(_ error: CocoaError) -> Bool {
    guard error.code == .fileWriteNoPermission, let underlying = error.underlying else { return false }
    let code = Mirror(reflecting: underlying).children.first { $0.label == "code" }?.value as? DWORD
    return code == DWORD(ERROR_SHARING_VIOLATION)
}
#endif
