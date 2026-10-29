// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

// TEMPORARY diagnostic for serverReplacesStaleSocketFile; never merged.
import Foundation
import Testing
import TowerKit
#if os(Windows)
import WinSDK

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

@Suite(.serialized) struct SocketFlakeDiagTests {
    /// Atomic writes (temp file via CRT _open, then MoveFileExW) while another thread keeps spawning children.
    @Test func atomicWriteWhileSpawning() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let done = Flag()
        let spawner = Thread {
            var spawned = 0
            while !done.isSet {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#) + #"\System32\ping.exe"#)
                p.arguments = ["-n", "2", "127.0.0.1"]
                p.standardOutput = FileHandle.nullDevice
                if (try? p.run()) != nil { spawned += 1 }
                Thread.sleep(forTimeInterval: 0.01)
            }
            print("DIAG spawned=\(spawned)")
        }
        spawner.start()
        var atomicFail: [String: Int] = [:], createFileFalse = 0, missing = 0, plainFail = 0
        for i in 0..<400 {
            let path = dir + "\\f\(i).sock"
            do { try Data("stale".utf8).write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { atomicFail["\(error)", default: 0] += 1 }
            let path2 = dir + "\\g\(i).sock"
            if !FileManager.default.createFile(atPath: path2, contents: Data("stale".utf8)) { createFileFalse += 1 }
            if !FileManager.default.fileExists(atPath: path2) { missing += 1 }
            // Control: a handle no child can inherit.
            let path3 = dir + "\\h\(i).sock"
            let h = path3.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            }
            if h == INVALID_HANDLE_VALUE { plainFail += 1 } else { CloseHandle(h) }
        }
        done.set()
        Thread.sleep(forTimeInterval: 2.5)
        print("DIAG atomicWriteWhileSpawning: atomicFail=\(atomicFail) createFileFalse=\(createFileFalse) missingAfterCreateFile=\(missing) nonInheritableFail=\(plainFail)")
    }
}
#endif
