// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

// Review I1: Claude Code's registry records when the session started (`startedAt`), so a reused pid (a process
// created later) is not mistaken for the session's own.

import Foundation
import Testing
@testable import AgentriseScene

@Suite struct SessionRegistryTests {
    /// 2027-01-15 08:00:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A date as FILETIME ticks (100 ns since 1601), what `GetProcessTimes` returns.
    private func fileTime(_ d: Date) -> UInt64 { UInt64((d.timeIntervalSince1970 + 11_644_473_600) * 10_000_000) }

    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agentrise-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func write(_ o: [String: Any], pid: Int32, in dir: URL) throws {
        try JSONSerialization.data(withJSONObject: o).write(to: dir.appendingPathComponent("\(pid).json"))
    }

    private var startedMs: Double { t0.timeIntervalSince1970 * 1000 }

    /// The Windows rule (`ProcessStart.matches`) over made-up creation times: a live pid created well before the session
    /// started is kept whatever `procStart` says; one created after `startedAt` + the margin is dropped; a file without
    /// `startedAt` falls back to liveness.
    @Test func loadDropsAnEntryWhosePidWasCreatedAfterTheSessionStarted() throws {
        let d = try dir()
        try write(["sessionId": "same", "pid": 101, "startedAt": startedMs, "procStart": "garbage", "procStartFt": "1"], pid: 101, in: d)
        try write(["sessionId": "reused", "pid": 202, "startedAt": startedMs, "procStart": "\(fileTime(t0))"], pid: 202, in: d)
        try write(["sessionId": "unstamped", "pid": 303, "procStart": "whatever"], pid: 303, in: d)
        // Every pid is alive; 202 now belongs to a process created an hour after the session started.
        let created: [Int32: Date] = [101: t0 - 3600, 202: t0 + 3600, 303: t0 + 3600]
        var asked: [Int32: ProcessStart?] = [:]
        let out = SessionRegistry.load(dir: d) { pid, start in
            asked[pid] = start
            return start.map { $0.matches(creation: fileTime(created[pid]!)) } ?? true
        }
        #expect(out.keys.sorted() == ["same", "unstamped"])
        #expect(out["same"]?.start == ProcessStart(startedAt: t0))
        // No startedAt: only liveness counts.
        #expect(asked[303] == .some(nil))
        #expect(out["unstamped"]?.start == nil)
        // The old entry point still checks liveness alone.
        #expect(SessionRegistry.load(dir: d, isRunning: { _ in true }).count == 3)
        #expect(SessionRegistry.load(dir: d, isRunning: { $0 != 101 }).keys.sorted() == ["reused", "unstamped"])
    }

    @Test func startIsReadFromStartedAtOnly() {
        #expect(ProcessStart(registry: ["startedAt": 1_800_000_000_000.0])?.startedAt == t0)
        #expect(ProcessStart(registry: ["startedAt": NSNumber(value: 1_800_000_000_000 as Int64)])?.startedAt == t0)
        #expect(ProcessStart(registry: ["procStart": "134444736000000000", "procStartFt": "134444736000000000"]) == nil)
        #expect(ProcessStart(registry: ["startedAt": "soon"]) == nil)
        #expect(ProcessStart(registry: ["startedAt": 0]) == nil)
        #expect(ProcessStart(registry: [:]) == nil)
    }

    @Test func matchesUnlessCreatedAfterTheStartPlusTheMargin() {
        let s = ProcessStart(startedAt: t0)
        #expect(s.matches(creation: fileTime(t0 - 3600)))   // long before: the session's own (or kept anyway)
        #expect(s.matches(creation: fileTime(t0 - 0.3)))    // the usual: created just before Claude Code noted the time
        #expect(s.matches(creation: fileTime(t0 + ProcessStart.margin - 0.5)))
        #expect(!s.matches(creation: fileTime(t0 + ProcessStart.margin + 0.5)))
        #expect(!s.matches(creation: fileTime(t0 + 3600)))  // a reused pid
        #expect(ProcessStart.margin == 10)
        #expect(ProcessStart.date(fileTime: fileTime(t0)) == t0)
    }
}
