// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if os(Windows)
import WinSDK
#endif

public enum ProcessAncestry {
#if os(Windows)
    /// The process that started this one, from a Toolhelp32 snapshot; 0 when it can't be found.
    public static func parentPID() -> Int32 {
        let me = Int32(bitPattern: GetCurrentProcessId())
        return snapshot()[me]?.parent ?? 0
    }

    /// The nearest process, starting with `pid` itself and then its parents, whose executable
    /// name (without `.exe`) starts with `prefix`, compared without regard to case.
    public static func ancestor(named prefix: String, from pid: Int32 = parentPID(), maxDepth: Int = 8) -> Int32? {
        let table = snapshot()
        let wanted = prefix.lowercased()
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 0, let info = table[current] else { return nil }
            var name = info.name.lowercased()
            if name.hasSuffix(".exe") { name.removeLast(4) }
            if name.hasPrefix(wanted) { return current }
            current = info.parent
        }
        return nil
    }

    /// The session's own agent process, for the liveness check (see the macOS version for Codex's daemon).
    public static func agentPid(for agent: AgentKind, from pid: Int32 = parentPID()) -> Int32? {
        guard let found = ancestor(named: agent.processName, from: pid) else { return nil }
        if agent == .codex, arguments(of: found)?.contains("--managed-daemon") == true { return nil }
        return found
    }

    /// The command line of another process, split the way the C runtime splits it, or nil when it
    /// can't be read: `NtQueryInformationProcess(ProcessCommandLineInformation)`, then `CommandLineToArgvW`.
    public static func arguments(of pid: Int32) -> [String]? {
        guard let query = ntQueryInformationProcess, pid > 0,
              let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION) | DWORD(PROCESS_VM_READ),
                                        false, DWORD(bitPattern: pid)) else { return nil }
        defer { CloseHandle(process) }
        // The first call only asks for the size; the reply is a UNICODE_STRING followed by its text.
        var size: ULONG = 0
        var status = query(process, processCommandLineInformation, nil, 0, &size)
        for _ in 0..<2 {
            guard status == statusInfoLengthMismatch, size > 0, size <= 1 << 20 else { return nil }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
            defer { buffer.deallocate() }
            status = query(process, processCommandLineInformation, buffer, size, &size)
            guard status >= 0 else { continue }                // grew between the calls: ask again
            // UNICODE_STRING: USHORT Length (bytes), USHORT MaximumLength, then the PWSTR Buffer.
            let length = Int(buffer.load(as: UInt16.self))
            guard length > 0 else { return [] }
            let bufferOffset = MemoryLayout<UnsafeRawPointer>.alignment
            guard let text = buffer.load(fromByteOffset: bufferOffset, as: UnsafeRawPointer?.self),
                  text >= UnsafeRawPointer(buffer),
                  text + length <= UnsafeRawPointer(buffer + Int(size)) else { return nil }   // points into the reply
            var units = Array(UnsafeBufferPointer(start: text.assumingMemoryBound(to: UInt16.self), count: length / 2))
            units.append(0)
            var argc: Int32 = 0
            guard let argv = CommandLineToArgvW(units, &argc) else { return nil }
            defer { LocalFree(UnsafeMutableRawPointer(argv)) }
            return (0..<Int(argc)).map { argv[$0].map { String(decodingCString: $0, as: UTF16.self) } ?? "" }
        }
        return nil
    }

    private typealias NtQueryInformationProcess = @convention(c) (
        HANDLE?, Int32, UnsafeMutableRawPointer?, ULONG, UnsafeMutablePointer<ULONG>?) -> Int32
    private static let processCommandLineInformation: Int32 = 60
    private static let statusInfoLengthMismatch = Int32(bitPattern: 0xC000_0004)

    /// WinSDK's Swift module doesn't declare it, so ntdll's export is looked up at run time.
    private static let ntQueryInformationProcess: NtQueryInformationProcess? = {
        guard let ntdll = "ntdll.dll".withCString(encodedAs: UTF16.self, { GetModuleHandleW($0) }),
              let proc = GetProcAddress(ntdll, "NtQueryInformationProcess") else { return nil }
        return unsafeBitCast(proc, to: NtQueryInformationProcess.self)
    }()

    /// pid -> (executable name, parent pid) for every process, from one Toolhelp32 snapshot.
    private static func snapshot() -> [Int32: (name: String, parent: Int32)] {
        let snap = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard let snap, snap != INVALID_HANDLE_VALUE else { return [:] }
        defer { CloseHandle(snap) }
        var table: [Int32: (name: String, parent: Int32)] = [:]
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        guard Process32FirstW(snap, &entry) else { return [:] }
        repeat {
            let name = withUnsafeBytes(of: entry.szExeFile) { raw -> String in
                let units = raw.bindMemory(to: UInt16.self)
                let end = units.firstIndex(of: 0) ?? units.count
                return String(decoding: units[..<end], as: UTF16.self)
            }
            table[Int32(bitPattern: entry.th32ProcessID)] = (name, Int32(bitPattern: entry.th32ParentProcessID))
        } while Process32NextW(snap, &entry)
        return table
    }
#else
    /// The process that started this one.
    public static func parentPID() -> Int32 {
        return getppid()
    }

    /// The nearest process, starting with `pid` itself and then its parents, whose name
    /// starts with `prefix`. The kernel keeps only the first 16 characters of a name.
    public static func ancestor(named prefix: String, from pid: pid_t = parentPID(), maxDepth: Int = 8) -> Int32? {
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1, let info = info(of: current) else { return nil }
            if info.name.hasPrefix(prefix) { return current }
            current = info.parent
        }
        return nil
    }

    /// The session's own agent process, for the liveness check. Codex's TUI runs its threads, and so its
    /// hooks, in a shared background app-server (`--managed-daemon`) that outlives every session and may
    /// serve several terminals: that process says nothing about one session, so none is reported.
    public static func agentPid(for agent: AgentKind, from pid: pid_t = parentPID()) -> Int32? {
        guard let found = ancestor(named: agent.processName, from: pid) else { return nil }
        if agent == .codex, arguments(of: found)?.contains("--managed-daemon") == true { return nil }
        return found
    }

    /// The command line (`argv`) of a process of the same user, or nil when it can't be read.
    public static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // argc, the executable path, NUL padding, then argc NUL-terminated arguments.
        let argc = buf.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args.count == argc ? args : nil
    }

    private static func info(of pid: pid_t) -> (name: String, parent: pid_t)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &proc, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (name, proc.kp_eproc.e_ppid)
    }
#endif
}
