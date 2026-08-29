import AppKit

/// `traffic-light doctor` — every way this can be half-installed, checked in
/// order, each with the one command that fixes it.
///
/// Setup has four independent moving parts (binary, daemon, hooks, push) and
/// three of them fail *silently*: a daemon that never started, hooks that are
/// registered but not loaded, and a push server nothing can reach all look
/// exactly like "no sessions need me right now".
enum Doctor {
    private enum Result { case ok(String), warn(String, String), bad(String, String) }

    static func run() {
        var results: [(String, Result)] = []

        // 1. Where everything lives.
        let fm = FileManager.default
        if fm.fileExists(atPath: Paths.home.path) {
            results.append(("state directory", .ok(Paths.display(Paths.home))))
        } else {
            results.append(("state directory", .bad("missing",
                "start the daemon once: traffic-light daemon")))
        }

        // 2. Is the daemon actually keeping state fresh? Not "is a process
        //    named traffic-light alive" — a wedged daemon passes that.
        let snapshot = Store.loadSnapshot()
        let age = Date().timeIntervalSince1970 - snapshot.updated
        if snapshot.updated == 0 {
            results.append(("daemon", .bad("has never written state",
                "sh install.sh")))
        } else if age > 30 {
            results.append(("daemon", .bad("state is \(Int(age))s stale — not running", restartHint())))
        } else {
            results.append(("daemon", .ok("state \(Int(age))s old")))
        }

        // 3. Events piling up means hooks are firing but nothing is draining.
        let backlog = (try? fm.contentsOfDirectory(atPath: Paths.inbox.path))?.count ?? 0
        if backlog > 500 {
            results.append(("inbox", .bad("\(backlog) unread events — the daemon is not draining",
                restartHint())))
        } else {
            results.append(("inbox", .ok("\(backlog) pending")))
        }

        // 4. Can we see Claude Code at all?
        let registry = Store.liveRegistry()
        if registry.isEmpty {
            results.append(("claude sessions", .warn("none running",
                "open a Claude Code session")))
        } else {
            results.append(("claude sessions", .ok("\(registry.count) live")))
        }

        // 4b. Payloads refused at the door. Normally zero, and normally
        //     uninteresting — but the filter is a positive test against this
        //     daemon's own vocabulary, so if Claude Code ever adds an event
        //     name this build has not heard of, the count is the only place
        //     that says so. A rising number beside a familiar-looking name is
        //     the signal to go and look.
        let ignored = snapshot.ignored
        if ignored.count > 0, let name = ignored.lastName {
            let ago = Int(Date().timeIntervalSince1970 - ignored.lastAt)
            results.append(("ignored events",
                .warn("\(ignored.count) not recognised, last \"\(name)\" \(ago)s ago",
                      "expected if another editor shares these hooks; "
                      + "otherwise report the name")))
        }

        // 5. The one that catches most bad installs. Hooks load at session
        //    start, so a correctly-installed plugin still reports nothing
        //    until a *new* session opens.
        let seen = Set(snapshot.sessions.keys)
        let covered = registry.keys.filter { seen.contains($0) }.count
        if registry.isEmpty {
            results.append(("hooks", .warn("cannot tell without a live session", "")))
        } else if covered == 0 {
            results.append(("hooks", .bad("no live session is sending events",
                "install the plugin, then open a NEW session — hooks load at session start")))
        } else if covered < registry.count {
            results.append(("hooks", .warn("\(covered) of \(registry.count) sessions covered",
                "open a new session, or restart Claude")))
        } else {
            results.append(("hooks", .ok("all \(covered) sessions reporting")))
        }

        // 6. Push, if it is meant to be on.
        let config = Config.load()
        if !config.push.enabled {
            results.append(("push", .warn("disabled", "sh scripts/setup-ntfy.sh, or set push.enabled")))
        } else if config.push.topic.isEmpty {
            results.append(("push", .bad("enabled but has no topic", "set push.topic in config.json")))
        } else if let health = URL(string: "\(config.push.server)/v1/health"),
                  reachable(health) {
            results.append(("push", .ok("\(config.push.server) reachable")))

            // 6b. Reachable is not the same as arriving.
            //
            // The check above asks the *server* whether it is alive, and says
            // nothing about the topic — so a topic the phone stopped listening
            // to passes it exactly like a working one. That is the shape of
            // the failure this whole feature has: a silent phone and seven
            // green ticks, with no way to tell whether the Mac never sent or
            // the phone never heard.
            //
            // Reading the topic's own cache back splits that in two. It cannot
            // prove anybody is subscribed — ntfy publishes no subscriber count,
            // so nothing here can ever know that — but it does say whether the
            // messages are landing on the topic the phone is supposed to be
            // watching, which is the half that is answerable from this side.
            switch published(topic: config.push.topic, server: config.push.server) {
            case .some(let count) where count > 0:
                let plural = count == 1 ? "message" : "messages"
                results.append(("push topic",
                    .ok("\(count) \(plural) published in the last hour")))
            case .some:
                // Not a fault. An hour in which nothing needed you is the
                // state this tool exists to produce, so this says what it
                // means and leaves the judgement to the person reading it.
                results.append(("push topic", .warn("nothing published in the last hour",
                    "normal if nothing needed you — if your phone is silent, check the "
                    + "ntfy app is subscribed to the topic in Settings → Notifications")))
            case .none:
                results.append(("push topic", .warn("could not be read",
                    "the server answered but the topic did not — try again, "
                    + "or check push.server in config.json")))
            }
        } else {
            results.append(("push", .bad("\(config.push.server) unreachable",
                "sh scripts/setup-ntfy.sh")))
        }

        // 7. A missing system sound fails silently at play time.
        let missing = config.bell.sounds.values.filter { NSSound(named: $0) == nil }
        if !config.bell.enabled {
            results.append(("bell", .warn("disabled", "set bell.enabled in config.json")))
        } else if missing.isEmpty {
            results.append(("bell", .ok("\(config.bell.sounds.count) sounds resolve")))
        } else {
            results.append(("bell", .bad("no such sound: \(missing.joined(separator: ", "))",
                "use a name from /System/Library/Sounds")))
        }

        // Report.
        print("")
        var problems = 0
        for (label, result) in results {
            let name = label.padding(toLength: 17, withPad: " ", startingAt: 0)
            switch result {
            case .ok(let detail):
                print("  \u{1B}[32m✓\u{1B}[0m \(name) \(dim)\(detail)\(reset)")
            case .warn(let detail, let fix):
                print("  \u{1B}[33m!\u{1B}[0m \(name) \(detail)")
                if !fix.isEmpty { print("    \(dim)\(fix)\(reset)") }
            case .bad(let detail, let fix):
                problems += 1
                print("  \u{1B}[31m✗\u{1B}[0m \(name) \(detail)")
                if !fix.isEmpty { print("    \(dim)→ \(fix)\(reset)") }
            }
        }
        print("")
        if problems > 0 { exit(1) }
    }

    /// `kickstart` only works on a service launchd already knows about. If the
    /// agent was booted out — or was never installed — it fails with "No such
    /// process", so telling someone to run it would be worse than useless.
    private static func restartHint() -> String {
        let label = "dev.supunte.traffic-light"
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")

        guard FileManager.default.fileExists(atPath: plist.path) else {
            return "sh install.sh"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(getuid())/\(label)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        return task.terminationStatus == 0
            ? "launchctl kickstart -k gui/\(getuid())/\(label)"
            : "launchctl bootstrap gui/\(getuid()) \(Paths.display(plist))"
    }

    /// How many messages the server is still holding for this topic.
    ///
    /// `nil` means the question could not be answered — a timeout, a refusal,
    /// a body that did not parse — which is deliberately not the same answer
    /// as zero. Zero is a quiet hour and is fine; unknown is worth saying out
    /// loud rather than reporting as quiet.
    ///
    /// Only the count is taken. The response carries every title and body sent
    /// in the window, and this is a diagnostic people paste into bug reports —
    /// so nothing from it, and not the topic either, ever reaches the terminal.
    private static func published(topic: String, server: String) -> Int? {
        guard let url = URL(string: "\(server)/\(topic)/json?poll=1&since=1h")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let semaphore = DispatchSemaphore(value: 0)
        var count: Int?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data else { return }
            // Newline-delimited JSON, one object per event. Only `message`
            // events are messages: the stream also carries keepalives and an
            // open marker, and counting those would report a healthy topic on
            // one that has never carried anything.
            count = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .filter { line in
                    guard let object = try? JSONSerialization.jsonObject(
                        with: Data(line.utf8)) as? [String: Any] else { return false }
                    return object["event"] as? String == "message"
                }
                .count
        }.resume()
        _ = semaphore.wait(timeout: .now() + 4)
        return count
    }

    private static func reachable(_ url: URL) -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 4)
        return ok
    }
}
