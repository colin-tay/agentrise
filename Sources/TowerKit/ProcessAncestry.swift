import Foundation

public enum ProcessAncestry {
    /// The nearest process, starting with `pid` itself and then its parents, whose name
    /// starts with `prefix`. The kernel keeps only the first 16 characters of a name.
    public static func ancestor(named prefix: String, from pid: pid_t = getppid(), maxDepth: Int = 8) -> Int32? {
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
    public static func agentPid(for agent: AgentKind, from pid: pid_t = getppid()) -> Int32? {
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
}
