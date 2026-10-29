// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK

/// Replaces a file atomically on Windows without racing child processes.
///
/// Foundation's atomic write creates its temporary file with an *inheritable* handle and then moves it over the
/// target. A child started meanwhile (`codex app-server`, or any `Process`) inherits that handle, and the move then
/// fails with `ERROR_SHARING_VIOLATION` (32) for as long as the child lives (Task 10, run 40844013498). Here the
/// temporary file, in the same directory, is opened with no security attributes (so its handle is never inherited),
/// written, flushed and closed before `MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)` puts it in place. Antivirus or
/// the search indexer may still hold the fresh file for a moment; such a move is retried a few times.
package enum SafeFile {
    package struct Failure: LocalizedError, Equatable {
        package let operation: String
        package let code: DWORD
        package var errorDescription: String? { "\(operation) 失败（Win32 错误 \(code)）" }
    }

    package static func write(_ data: Data, to url: URL) throws {
        let target = nativePath(of: url)
        let dir = nativePath(of: url.deletingLastPathComponent())
        let tmp = dir + "\\." + url.lastPathComponent + "." + UUID().uuidString.prefix(8) + ".agentrise-tmp"
        let handle = tmp.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(0x4000_0000) /* GENERIC_WRITE */, 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw Failure(operation: "创建临时文件", code: GetLastError()) }
        var ok = true
        var code: DWORD = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var offset = 0
            while ok, offset < buf.count {
                let chunk = DWORD(min(buf.count - offset, 1 << 30))
                var written: DWORD = 0
                if !WriteFile(handle, buf.baseAddress! + offset, chunk, &written, nil) || written == 0 {
                    ok = false; code = GetLastError()
                }
                offset += Int(written)
            }
        }
        if ok, !FlushFileBuffers(handle) { ok = false; code = GetLastError() }
        CloseHandle(handle)
        guard ok else {
            _ = tmp.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
            throw Failure(operation: "写入临时文件", code: code)
        }
        var pause: DWORD = 20
        for attempt in 1...6 {
            let moved = tmp.withCString(encodedAs: UTF16.self) { t in
                target.withCString(encodedAs: UTF16.self) { MoveFileExW(t, $0, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) }
            }
            if moved { return }
            code = GetLastError()
            guard attempt < 6, code == DWORD(ERROR_SHARING_VIOLATION) || code == DWORD(ERROR_ACCESS_DENIED) else { break }
            Sleep(pause)
            pause *= 2
        }
        _ = tmp.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
        throw Failure(operation: "替换 \(url.lastPathComponent)", code: code)
    }

    /// `C:\…` with backslashes and no trailing separator.
    package static func nativePath(of url: URL) -> String {
        var p = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
        p = p.replacingOccurrences(of: "/", with: "\\")
        while p.count > 3, p.hasSuffix("\\") { p.removeLast() }
        return p
    }
}
#endif
