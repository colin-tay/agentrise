// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

// TEMPORARY diagnostic for serverReplacesStaleSocketFile; never merged.
import Foundation
import Testing
import TowerKit
#if os(Windows)
import WinSDK

@Suite(.serialized) struct SocketFlakeDiagTests {
    private func run(_ label: String, atomic: Bool, waitBeforeWrite: Double) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "\\s.sock"
        var existsAfterStop = 0, writeFailed = 0, missingRightAfter = 0, missingLater = 0
        var errors: [String: Int] = [:]
        let n = 200
        for _ in 0..<n {
            let server = try SocketServer(path: path) { _ in }
            server.stop()
            if FileManager.default.fileExists(atPath: path) { existsAfterStop += 1 }
            if waitBeforeWrite > 0 { Thread.sleep(forTimeInterval: waitBeforeWrite) }
            do {
                try Data("stale".utf8).write(to: URL(fileURLWithPath: path), options: atomic ? .atomic : [])
            } catch {
                writeFailed += 1
                errors["\(error)", default: 0] += 1
            }
            if !FileManager.default.fileExists(atPath: path) { missingRightAfter += 1 }
            Thread.sleep(forTimeInterval: 0.03)
            if !FileManager.default.fileExists(atPath: path) { missingLater += 1 }
            _ = path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
        }
        print("DIAG \(label): n=\(n) existsAfterStop=\(existsAfterStop) writeFailed=\(writeFailed) missingRightAfter=\(missingRightAfter) missingLater30ms=\(missingLater) errors=\(errors)")
    }

    @Test func diagAtomic() throws { try run("atomic", atomic: true, waitBeforeWrite: 0) }
    @Test func diagPlain() throws { try run("plain", atomic: false, waitBeforeWrite: 0) }
    @Test func diagAtomicAfter100ms() throws { try run("atomic+100ms", atomic: true, waitBeforeWrite: 0.1) }

    /// Does a socket file still exist, and can it be opened, while its listener is open / after it closes?
    @Test func diagDeleteWhileListening() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "\\s.sock"
        let server = try SocketServer(path: path) { _ in }
        let ok = path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
        let err = ok ? 0 : GetLastError()
        let existsAfterDelete = FileManager.default.fileExists(atPath: path)
        var writeErr = "none"
        do { try Data("x".utf8).write(to: URL(fileURLWithPath: path), options: .atomic) } catch { writeErr = "\(error)" }
        let existsAfterWrite = FileManager.default.fileExists(atPath: path)
        server.stop()
        Thread.sleep(forTimeInterval: 0.2)
        let existsAfterClose = FileManager.default.fileExists(atPath: path)
        print("DIAG deleteWhileListening: deleteOK=\(ok) err=\(err) existsAfterDelete=\(existsAfterDelete) writeErr=\(writeErr) existsAfterWrite=\(existsAfterWrite) existsAfterStopAndClose=\(existsAfterClose)")
    }
}
#endif
