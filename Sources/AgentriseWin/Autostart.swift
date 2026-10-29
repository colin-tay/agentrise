// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK

/// Start at login (spec §5.6): the value `Agentrise` under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, the
/// exe's full path in double quotes. It counts as on only when the value runs *this* exe, so after the user moves the
/// unzipped folder Settings shows it off and ticking it again points it at the new place.
package struct Autostart {
    package static let runKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    package static let valueName = "Agentrise"

    /// The key under `HKEY_CURRENT_USER` (tests use their own).
    package var keyPath: String
    package var exePath: String

    package init(keyPath: String = Autostart.runKey, exePath: String = Autostart.currentExe()) {
        self.keyPath = keyPath; self.exePath = exePath
    }

    /// What the value holds when it is on.
    package var command: String { "\"\(exePath)\"" }

    package struct Failure: LocalizedError {
        package let status: Int32
        package var errorDescription: String? { "无法修改开机自启（注册表错误 \(status)）" }
    }

    /// The current user's choice, for `Autostart()`.
    package static var isEnabled: Bool { Autostart().isEnabled }
    package static func set(_ on: Bool) throws { try Autostart().set(on) }

    package var isEnabled: Bool {
        guard let v = value else { return false }
        return v.compare(command, options: .caseInsensitive) == .orderedSame
    }

    /// The value as it is now (nil when there is none).
    package var value: String? {
        guard let key = open(write: false) else { return nil }
        defer { RegCloseKey(key) }
        var type: DWORD = 0
        var size: DWORD = 0
        let name = Array(Self.valueName.utf16) + [0]
        guard RegQueryValueExW(key, name, nil, &type, nil, &size) == 0, type == DWORD(REG_SZ), size > 0 else { return nil }
        var buf = [UInt16](repeating: 0, count: Int(size) / 2 + 1)
        let r = buf.withUnsafeMutableBytes { RegQueryValueExW(key, name, nil, &type, $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &size) }
        guard r == 0 else { return nil }
        let n = buf.firstIndex(of: 0) ?? buf.count
        return String(decoding: buf.prefix(n), as: UTF16.self)
    }

    package func set(_ on: Bool) throws {
        guard let key = open(write: true) else { throw Failure(status: Int32(bitPattern: GetLastError())) }
        defer { RegCloseKey(key) }
        let name = Array(Self.valueName.utf16) + [0]
        if on {
            let data = Array(command.utf16) + [0]
            let r = data.withUnsafeBytes {
                RegSetValueExW(key, name, 0, DWORD(REG_SZ), $0.baseAddress?.assumingMemoryBound(to: BYTE.self), DWORD($0.count))
            }
            if r != 0 { throw Failure(status: r) }
        } else {
            let r = RegDeleteValueW(key, name)
            if r != 0, r != Int32(ERROR_FILE_NOT_FOUND) { throw Failure(status: r) }
        }
    }

    /// `HKEY_CURRENT_USER` (a macro Swift doesn't import: `(HKEY)(ULONG_PTR)(LONG)0x80000001`).
    static let currentUser = HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001)))

    private func open(write: Bool) -> HKEY? {
        var key: HKEY?
        let access: DWORD = write ? 0x0002 | 0x0001 : 0x0001   // KEY_SET_VALUE | KEY_QUERY_VALUE
        let path = Array(keyPath.utf16) + [0]
        let r: Int32
        if write {
            r = RegCreateKeyExW(Self.currentUser, path, 0, nil, 0, access, nil, &key, nil)
        } else {
            r = RegOpenKeyExW(Self.currentUser, path, 0, access, &key)
        }
        if r != 0 { SetLastError(DWORD(bitPattern: r)) }
        return r == 0 ? key : nil
    }

    /// This process's exe (`GetModuleFileNameW`), long paths included.
    package static func currentExe() -> String {
        var buf = [UInt16](repeating: 0, count: 1024)
        while true {
            let n = Int(GetModuleFileNameW(nil, &buf, DWORD(buf.count)))
            if n < buf.count - 1 || buf.count >= 32_768 { return String(decoding: buf.prefix(n), as: UTF16.self) }
            buf = [UInt16](repeating: 0, count: buf.count * 2)
        }
    }
}
#endif
