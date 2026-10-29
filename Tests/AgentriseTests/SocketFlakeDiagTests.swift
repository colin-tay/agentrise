// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

// TEMPORARY diagnostic for serverReplacesStaleSocketFile; never merged.
import Foundation
import Testing
import TowerKit
#if os(Windows)
import WinSDK

@Suite struct SocketFlakeDiagTests {
    private func attrs(_ path: String) -> String {
        let a = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        if a == INVALID_FILE_ATTRIBUTES { return "INVALID err=\(GetLastError())" }
        return String(a, radix: 16)
    }

    @Test(arguments: 0..<300) func replicate(_ i: Int) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "\\s.sock"
        let first = try SocketServer(path: path) { _ in }
        first.stop()
        let afterStop = attrs(path)
        let created = FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let afterCreate = attrs(path)
        let exists = FileManager.default.fileExists(atPath: path)
        if !exists || !created || afterStop != "INVALID err=2" {
            try? await Task.sleep(nanoseconds: 300_000_000)
            print("DIAG case \(i): afterStop=\(afterStop) created=\(created) afterCreate=\(afterCreate) exists=\(exists) later: attrs=\(attrs(path)) exists=\(FileManager.default.fileExists(atPath: path))")
        }
    }
}
#endif
