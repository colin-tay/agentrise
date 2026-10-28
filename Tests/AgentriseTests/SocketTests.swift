// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit

/// Collects lines handed to `onLine` from whatever thread the server uses.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    func add(_ line: Data) { lock.lock(); lines.append(line); lock.unlock() }

    var snapshot: [Data] { lock.lock(); defer { lock.unlock() }; return lines }

    /// Waits until at least `count` lines arrived or the deadline passes, then returns what arrived.
    func wait(for count: Int, timeout: TimeInterval = 2) async -> [Data] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = snapshot
            if now.count >= count { return now }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return snapshot
    }
}

/// A short, fresh directory: macOS `sun_path` holds only 104 bytes.
private func makeTempDir(suffix: String = "") throws -> String {
    let rand = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    #if os(Windows)
    var base = FileManager.default.temporaryDirectory.withUnsafeFileSystemRepresentation { String(cString: $0!) }
    while base.hasSuffix("\\") || base.hasSuffix("/") { base.removeLast() }
    let dir = base + "\\ar-\(rand)\(suffix)"
    #else
    let dir = "/tmp/ar-\(rand)\(suffix)"
    #endif
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func socketPath(in dir: String) -> String {
    #if os(Windows)
    dir + "\\s.sock"
    #else
    dir + "/s.sock"
    #endif
}

/// Leaves something at `path` that a crashed earlier run could have left behind.
private func leaveStaleFile(at path: String) {
    #if os(Windows)
    // A closed AF_UNIX socket leaves its file behind; a plain file stands in for it.
    FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
    #else
    // The macOS server only removes sockets the current user owns, so leave a socket nobody listens on.
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    _ = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    close(fd)
    #endif
}

@Suite struct SocketTests {
    private func roundTrip(in dir: String) async throws {
        let path = socketPath(in: dir)
        let box = LineBox()
        let server = try SocketServer(path: path) { box.add($0) }
        defer { server.stop() }
        #expect(SocketClient.send(Data("a\n".utf8), to: path))
        let lines = await box.wait(for: 1)
        #expect(lines == [Data("a".utf8)])
    }

    @Test func lineRoundTrips() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await roundTrip(in: dir)
    }

    @Test func sendReturnsFalseQuicklyWithNoListener() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let start = Date()
        let ok = SocketClient.send(Data("a\n".utf8), to: socketPath(in: dir))
        #expect(!ok)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func trailingLineWithoutNewlineIsDelivered() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = socketPath(in: dir)
        let box = LineBox()
        let server = try SocketServer(path: path) { box.add($0) }
        defer { server.stop() }
        #expect(SocketClient.send(Data("tail".utf8), to: path))
        let lines = await box.wait(for: 1)
        #expect(lines == [Data("tail".utf8)])
    }

    @Test func oversizeLineIsDropped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = socketPath(in: dir)
        let box = LineBox()
        let server = try SocketServer(path: path) { box.add($0) }
        defer { server.stop() }
        // Both lines on one connection, so "ok" is only handled after the oversize line.
        var payload = Data(repeating: 0x61, count: EventSlimmer.maxLineBytes + 1)
        payload.append(Data("\nok\n".utf8))
        #expect(SocketClient.send(payload, to: path))
        let lines = await box.wait(for: 1)
        #expect(lines == [Data("ok".utf8)])
    }

    @Test func serverReplacesStaleSocketFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = socketPath(in: dir)
        let first = try SocketServer(path: path) { _ in }
        first.stop()
        leaveStaleFile(at: path)
        #expect(FileManager.default.fileExists(atPath: path))
        try await roundTrip(in: dir)
    }

    @Test func roundTripInNonASCIIDirectory() async throws {
        let dir = try makeTempDir(suffix: "-测试")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await roundTrip(in: dir)
    }
}
