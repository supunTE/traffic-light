import Foundation

/// How a command run *inside* a Claude Code session works out which Session it
/// belongs to.
///
/// There is no environment variable for it. What there is: `~/.claude/sessions`
/// is keyed by the session process's PID, so walking our own process ancestry
/// and asking "does this ancestor have a registry file?" identifies us exactly.
/// The first hit is the answer — a session is not nested inside another.
enum SelfIdentity {
    static func currentSession() -> RegistryRecord? {
        var pid = getpid()
        // Deep enough for sh → claude → helper → Claude.app and then some,
        // bounded so a cycle or a surprise can never hang a Distress Call.
        for _ in 0..<12 {
            if let record = registryRecord(forPid: pid) { return record }
            guard let parent = parentPid(of: pid), parent > 1 else { return nil }
            pid = parent
        }
        return nil
    }

    private static func registryRecord(forPid pid: pid_t) -> RegistryRecord? {
        let url = Paths.registry.appending(path: "\(pid).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RegistryRecord.self, from: data)
    }

    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
