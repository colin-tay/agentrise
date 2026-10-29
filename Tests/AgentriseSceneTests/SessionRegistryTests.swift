// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

// Review I1: Claude Code's registry records when its process started, so a reused pid is not mistaken for it.

import Foundation
import Testing
@testable import AgentriseScene

@Suite struct SessionRegistryTests {
    /// 2027-01-15 08:00:00 UTC as FILETIME ticks (100 ns since 1601).
    private let created: UInt64 = (1_800_000_000 + 11_644_473_600) * 10_000_000

    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agentrise-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func write(_ o: [String: Any], pid: Int32, in dir: URL) throws {
        try JSONSerialization.data(withJSONObject: o).write(to: dir.appendingPathComponent("\(pid).json"))
    }

    @Test func loadDropsAnEntryWhosePidIsAliveButStartedAtAnotherTime() throws {
        let d = try dir()
        try write(["sessionId": "same", "pid": 101, "procStartFt": "\(created)"], pid: 101, in: d)
        try write(["sessionId": "reused", "pid": 202, "procStartFt": "\(created)"], pid: 202, in: d)
        try write(["sessionId": "unstamped", "pid": 303], pid: 303, in: d)
        // Every pid is alive; 202 now belongs to a process created an hour later.
        let live: [Int32: UInt64] = [101: created, 202: created + 36_000_000_000, 303: created]
        var asked: [Int32: ProcessStart?] = [:]
        let out = SessionRegistry.load(dir: d) { pid, start in
            asked[pid] = start
            return start.flatMap { $0.matches(creation: live[pid]!) } ?? true
        }
        #expect(out.keys.sorted() == ["same", "unstamped"])
        #expect(out["same"]?.start == ProcessStart(fileTime: "\(created)"))
        // No start time: only liveness counts.
        #expect(asked[303] == .some(nil))
        #expect(out["unstamped"]?.start == nil)
        // The old entry point still checks liveness alone.
        #expect(SessionRegistry.load(dir: d, isRunning: { _ in true }).count == 3)
        #expect(SessionRegistry.load(dir: d, isRunning: { $0 != 101 }).keys.sorted() == ["reused", "unstamped"])
    }

    @Test func startIsReadFromStringsOrNumbers() {
        #expect(ProcessStart(registry: ["procStartFt": "12", "procStart": "34"]) == ProcessStart(fileTime: "12", procStart: "34"))
        #expect(ProcessStart(registry: ["procStart": NSNumber(value: 134_444_736_000_000_000 as UInt64)])?.procStart == "134444736000000000")
        #expect(ProcessStart(registry: ["procStart": ""]) == nil)
        #expect(ProcessStart(registry: [:]) == nil)
    }

    @Test func fileTimeMatchesOnlyTheSameCreation() {
        let s = ProcessStart(fileTime: "\(created)")
        #expect(s.matches(creation: created) == true)
        #expect(s.matches(creation: created + 9_000) == true)        // rounding (a JS number past 2^53)
        #expect(s.matches(creation: created + 600_000_000) == false) // a minute later: another process
        #expect(s.matches(creation: created - 600_000_000) == false)
        // procStartFt wins over procStart.
        #expect(ProcessStart(fileTime: "\(created)", procStart: "1").matches(creation: created) == true)
    }

    /// `procStart` is FILETIME below 3e17 and .NET ticks above, as Claude Code reads it; .NET ticks may be UTC or the
    /// local time (`Win32_Process.CreationDate`).
    @Test func procStartAcceptsBothScales() {
        let ticks = created + ProcessStart.dotNetTicksAtFileTimeEpoch
        let eightHours = 8 * 3600
        let local = ticks + UInt64(eightHours) * 10_000_000
        let offset: (UInt64) -> Int = { _ in eightHours }
        #expect(ProcessStart(procStart: "\(created)").matches(creation: created, utcOffset: offset) == true)
        #expect(ProcessStart(procStart: "\(ticks)").matches(creation: created, utcOffset: offset) == true)
        #expect(ProcessStart(procStart: "\(local)").matches(creation: created, utcOffset: offset) == true)
        #expect(ProcessStart(procStart: "\(ticks)").matches(creation: created + 36_000_000_000, utcOffset: offset) == false)
        #expect(ProcessStart(procStart: "\(local)").matches(creation: created, utcOffset: { _ in -5 * 3600 }) == false)
        #expect(ProcessStart(procStart: "\(created)").matches(creation: created + 36_000_000_000) == false)
    }

    /// A start time this can't read (macOS writes a date string) leaves the decision to liveness.
    @Test func unreadableStartIsNoAnswer() {
        #expect(ProcessStart(procStart: "Thu Jan 15 08:00:00 2027").matches(creation: created) == nil)
        #expect(ProcessStart(fileTime: "soon").matches(creation: created) == nil)
        #expect(ProcessStart(fileTime: "soon", procStart: "\(created)").matches(creation: created) == true)
    }
}
