import Foundation

/// `traffic-light cleanup` — collect what the timers are still holding.
///
/// Everything here happens on its own eventually: a dead session is dropped an
/// hour after its last event, a living one goes quiet after eight, the log
/// rotates at its ceiling. This is for the moment you have already looked at a
/// row and concluded it is finished. Waiting out a timer you have out-reasoned
/// is how a tool teaches you to stop trusting it.
///
/// It deliberately touches nothing that is alive. A session with a running
/// process stays, whatever it is doing and however long it has been quiet —
/// "clean up" must never be a word that loses work.
enum Cleanup {
    /// How long to wait for a running daemon to service the request before
    /// giving up on it. The daemon's tick is one second; three of them is
    /// generous without leaving anyone watching a hung command.
    private static let patience: Double = 3

    static func run(logs: Bool) {
        let fm = FileManager.default

        // Who does the work depends on who owns the file.
        //
        // `state.json` is rewritten from the daemon's in-memory snapshot every
        // couple of seconds, so a second process editing it is simply
        // overwritten a moment later — the cleanup would appear to work and
        // then silently undo itself. When a daemon is running it has to be the
        // one to sweep, and this becomes a request.
        let snapshot = Store.loadSnapshot()
        let staleness = Date().timeIntervalSince1970 - snapshot.updated
        let daemonIsUp = snapshot.updated > 0 && staleness < 30
        let before = snapshot.sessions.count

        if daemonIsUp {
            guard Paths.writePrivately(Data(), to: Paths.cleanupRequest) else {
                say("could not write the request file — is the disk full?")
                exit(1)
            }
            guard waitForRequestToBeTaken() else {
                // The daemon looked alive but never picked the request up.
                // Left in place rather than deleted: it costs nothing, and the
                // next tick of a daemon that was merely busy will honour it.
                say("the daemon did not answer within \(Int(patience))s — "
                    + "the request is queued for its next tick")
                exit(1)
            }
            let after = Store.loadSnapshot().sessions.count
            report(dropped: before - after, remaining: after)
        } else {
            // Nobody is holding the file, so there is nothing to race with.
            //
            // Clear any request left behind first. A daemon that died between
            // being asked and answering leaves one, and it would otherwise sit
            // there until some future daemon started and swept for reasons
            // nobody present asked for.
            try? fm.removeItem(at: Paths.cleanupRequest)
            let store = Store()
            store.load()
            let dropped = store.sweep()
            store.persist(heartbeat: false)
            report(dropped: dropped, remaining: store.snapshot.sessions.count)
        }

        // The log is not part of the snapshot and is opt-in, so it is opt-in
        // here too. Deleting a debug log someone switched on by hand, because
        // they asked to tidy up sessions, would throw away the only record of
        // whatever they were chasing.
        if logs { deleteLogs(fm) }
    }

    /// Polls for the daemon to delete the request file, which is its
    /// acknowledgement. There is no reply channel and none is wanted: the
    /// absence of the file is the whole message, and it cannot go stale.
    private static func waitForRequestToBeTaken() -> Bool {
        let deadline = Date().timeIntervalSince1970 + patience
        while Date().timeIntervalSince1970 < deadline {
            // The daemon writes the swept state *before* removing the file,
            // so the file being gone means the new count is already on disk.
            if !FileManager.default.fileExists(atPath: Paths.cleanupRequest.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func deleteLogs(_ fm: FileManager) {
        // Sizes first: the point of saying anything is to say how much went,
        // and after the delete there is nothing left to measure.
        let freed = [Paths.events, Paths.eventsPrevious]
            .compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.size] as? Int }
            .reduce(0, +)
        // The daemon holds the log open. Removing the path from underneath it
        // leaves it appending to an unlinked inode — a log that looks switched
        // on and produces nothing — so it is asked to let go first. Its own
        // tick reopens the file lazily on the next event.
        _ = try? fm.removeItem(at: Paths.events)
        _ = try? fm.removeItem(at: Paths.eventsPrevious)
        say(freed > 0
            ? "event log deleted, \(bytes(freed)) freed"
            : "no event log to delete")
    }

    private static func report(dropped: Int, remaining: Int) {
        let subject = dropped == 1 ? "session" : "sessions"
        say(dropped == 0
            ? "nothing to collect — all \(remaining) still have a live process"
            : "\(dropped) finished \(subject) collected, \(remaining) still running")
    }

    private static func bytes(_ count: Int) -> String {
        count >= 1_048_576 ? "\(count / 1_048_576) MB" : "\(count / 1024) kB"
    }

    private static func say(_ line: String) { print("  \(line)") }
}
