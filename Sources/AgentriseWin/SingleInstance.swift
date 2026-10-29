// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK

/// One Agentrise per user session: a named mutex `Local\Agentrise-<user SID>` decides who runs. The first instance
/// holds it for its whole life (Windows lets go of it when the process ends, however it ends, so a crash leaves
/// nothing behind). A second instance finds the first one's window, asks it to come forward and exits with 0.
///
/// The socket never decides: the instance that holds the mutex owns `tower.sock` and replaces a stale file a crashed
/// instance left (`SocketServer.init` deletes it before binding), so nothing depends on `SocketServer.stop()`.
package final class SingleInstance {
    private let handle: HANDLE

    /// `Local\Agentrise-S-1-5-21-…`: per user (the SID) and per logon session (`Local\`).
    package static var mutexName: String { "Local\\Agentrise-\(currentUserSID() ?? "unknown")" }

    /// Takes the mutex; nil when another instance holds it.
    package static func acquire(name: String = mutexName) -> SingleInstance? {
        let (handle, error) = withWide(name) { (CreateMutexW(nil, true, $0), GetLastError()) }
        guard let h = handle else { return nil }
        if error == DWORD(ERROR_ALREADY_EXISTS) {
            CloseHandle(h)
            return nil
        }
        return SingleInstance(handle: h)
    }

    private init(handle: HANDLE) { self.handle = handle }

    deinit {
        ReleaseMutex(handle)
        CloseHandle(handle)
    }

    /// The message the first instance's window answers by coming forward (registered, so it is unique system-wide).
    package static let showMessage: UINT = withWide("Agentrise.ShowWindow") { RegisterWindowMessageW($0) }

    /// Asks the running instance's window to show itself. False when no window was found (the other instance is
    /// still starting, or it is a test holding the mutex).
    @discardableResult
    package static func signalFirstInstance() -> Bool {
        guard let hwnd = withWide(TowerWindow.className, { FindWindowW($0, nil) }) else { return false }
        // We were started by the user, so we may hand the foreground on to the window's process.
        var pid: DWORD = 0
        GetWindowThreadProcessId(hwnd, &pid)
        if pid != 0 { AllowSetForegroundWindow(pid) }
        PostMessageW(hwnd, showMessage, 0, 0)
        return true
    }

    /// The current user's SID as text (`S-1-5-21-…`), formatted by hand (no sddl.h).
    package static func currentUserSID() -> String? {
        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token).boolValue, let token else { return nil }
        defer { CloseHandle(token) }
        var size: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &size)
        guard size > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { buffer.deallocate() }
        guard GetTokenInformation(token, TokenUser, buffer, size, &size).boolValue else { return nil }
        guard let sid = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid,
              IsValidSid(sid).boolValue, let auth = GetSidIdentifierAuthority(sid)?.pointee,
              let count = GetSidSubAuthorityCount(sid)?.pointee else { return nil }
        let v = auth.Value
        let bytes = [v.0, v.1, v.2, v.3, v.4, v.5].map(UInt64.init)
        let authority = bytes.reduce(UInt64(0)) { $0 << 8 | $1 }
        var text = "S-1-\(authority)"
        for i in 0..<DWORD(count) {
            if let p = GetSidSubAuthority(sid, i) { text += "-\(p.pointee)" }
        }
        return text
    }
}
#endif
