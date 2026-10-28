// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation

/// Collects lines handed to `onLine` from whatever thread the server uses.
final class LineBox: @unchecked Sendable {
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
func makeTempDir(suffix: String = "") throws -> String {
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
