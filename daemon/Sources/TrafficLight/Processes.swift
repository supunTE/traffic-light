import Darwin
import Foundation

/// Looks at what a Claude Code session has actually spawned.
///
/// This exists to separate two states that hooks cannot tell apart. A
/// `PreToolUse` with no matching `PostToolUse` means either *a human is being
/// waited on* or *the tool is genuinely still running*. Nothing fires to
/// distinguish them: a permission prompt emits no event at all.
///
/// But the process table does distinguish them. Claude Code does not spawn the
/// command until permission is granted, so:
///
///   - command running   → a child spawned *after* the tool call began
///   - prompt waiting    → nothing new, only the MCP servers from startup
///
/// Verified on two live sessions: both carried `node`, `npm` and an MCP server
/// throughout, and a fresh child appeared only while a tool was executing.
enum Processes {
    /// The table is read at most a few times a second and only when a tool has
    /// already outlived the threshold, so a short cache keeps a screen full of
    /// sessions to one enumeration.
    private static var cache: (at: Double, table: [Entry])?

    struct Entry {
        let pid: Int32
        let ppid: Int32
        let started: Double
    }
    private static let cacheLifetime: Double = 0.5

    /// Did this session spawn anything *after* the given moment?
    ///
    /// The persistent MCP servers started when the session did, so they never
    /// match. A command spawned to satisfy a tool call always does. Hooks also
    /// spawn children, but no hook fires while a permission prompt is open, so
    /// there is nothing to confuse it with.
    ///
    /// Start time, deliberately, and not a list of shell names: `zsh -c "npm
    /// test"` usually *execs* into the command, so the process keeps its pid
    /// but is renamed from `zsh` to `npm`. A name check then reports the
    /// command as not running while it plainly is. A start time cannot be
    /// renamed.
    ///
    /// One second of slack absorbs the skew between the hook's `date +%s` and
    /// the kernel's own clock.
    static func spawnedSomething(since when: Double, of pid: Int32) -> Bool {
        table().contains { $0.ppid == pid && $0.started > when - 1 }
    }

    /// When this pid started, or nil if nothing holds it.
    ///
    /// A pid on its own does not identify a process. The kernel reuses them,
    /// and a session's pid outlives the session in `state.json` — so `kill(pid,
    /// 0)` succeeding proves only that *something* answers to that number.
    /// Paired with the start time it identifies one process for as long as it
    /// runs, which is the whole question being asked.
    static func startTime(of pid: Int32) -> Double? {
        table().first { $0.pid == pid }?.started
    }

    private static func table() -> [Entry] {
        let now = Date().timeIntervalSince1970
        if let cache, now - cache.at < cacheLifetime { return cache.table }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let table = procs.prefix(size / stride).map { proc in
            Entry(pid: proc.kp_proc.p_pid,
                  ppid: proc.kp_eproc.e_ppid,
                  started: Double(proc.kp_proc.p_starttime.tv_sec)
                      + Double(proc.kp_proc.p_starttime.tv_usec) / 1_000_000)
        }
        cache = (now, table)
        return table
    }
}
