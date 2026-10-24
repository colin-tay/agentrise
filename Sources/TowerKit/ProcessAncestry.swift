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
