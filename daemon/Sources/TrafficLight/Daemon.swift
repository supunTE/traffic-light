import Foundation

/// A change from one Signal to another for one Session. Bells ring on
/// Transitions, never on Signals — which is what stops a Session sitting in
/// `Asking` from ringing continuously.
struct Transition {
    /// Which Session this is about.
    ///
    /// Carried for the same reason `from` is deliberately not: something reads
    /// it. A Transition may now wait a few seconds before it is delivered, and
    /// in that window it has to be answerable to two questions — *is this the
    /// same session as the one already waiting* and *is what it says still
    /// true*. Neither can be asked of a name, which two sessions in one
    /// project share.
    let sessionId: String
    let name: String
    /// The project directory's basename, carried so per-project rules can be
    /// applied to a Transition without looking the Session up again.
    let project: String
    /// Only the Signal arrived at. There is deliberately no `from`: nothing
    /// rings, pushes or renders differently for where a Session came from, and
    /// a field carried for years without a reader is a field that quietly
    /// stops being true. `tick` still needs the previous Signal to *decide*
    /// there was a Transition at all — it just has no reason to pass it on.
    let to: Signal
    let note: String
    let text: String?
}

protocol Renderer: AnyObject {
    func render(rows: [Row], aggregate: Signal, transitions: [Transition],
                attention: AttentionState)
}

enum Daemon {
    /// One daemon, ever.
    ///
    /// Two of them means two status items, two floating bars, two of every
    /// chime — and worse, two ingesters racing to delete the same inbox files,
    /// which is the one thing `ingest()` is documented as unable to survive.
    /// It is easy to end up with two: launchd starts one, and double-clicking
    /// the app starts another.
    ///
    /// An advisory lock rather than a PID file, because the kernel releases it
    /// when the process dies however it dies — a PID file outlives a crash and
    /// then locks out the restart that was supposed to recover from it.
    private static var lock: Int32 = -1

    private static func claimSingleton() -> Bool {
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        let path = Paths.home.appending(path: "daemon.lock").path
        lock = open(path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { return true }   // cannot lock: do not block the light
        return flock(lock, LOCK_EX | LOCK_NB) == 0
    }

    /// `--once` drains the inbox, renders a single frame and exits. It is how
    /// the daemon is tested, and the only supported way to ingest without a
    /// long-running process — two ingesters would race to delete the same
    /// inbox files.
    static func run(headless: Bool, once: Bool = false) {
        // `--once` takes the lock too. The comment here used to say it must
        // not fight a running daemon and then skipped the lock, which is what
        // let it fight one: both processes enumerate the inbox, both delete the
        // same files, and each writes its own snapshot over state.json. That is
        // the one thing `ingest()` is documented as unable to survive, and
        // `--once` is advertised in `--help`.
        if !claimSingleton() {
            FileHandle.standardError.write(Data(
                "traffic-light: another daemon is already running\n".utf8))
            return
        }
        // Built before the Store, which needs it: the event log reads its
        // settings on every write so the text can be switched on for a
        // debugging session and off again without a restart.
        let config = ConfigStore()
        let store = Store(config: config)
        store.load()

        var renderers: [Renderer] = []
        if headless {
            renderers.append(TerminalRenderer())
        } else {
            let ui = makeUIRenderers(config: config)
            // Settings shows live health, and the menu bar renderer is what
            // opens it — but a Renderer owning the Store would let it ingest,
            // and two ingesters race to delete the same inbox files.
            (ui.first as? MenuBarRenderer)?.snapshotProvider = { [weak store] in
                store?.snapshot ?? Snapshot()
            }
            renderers.append(contentsOf: ui)
        }
        // Both are always attached and decide for themselves whether they are
        // switched on, so toggling either in config.json takes effect without
        // a restart.
        renderers.append(BellRenderer(store: config))
        renderers.append(PushRenderer(store: config))

        var previous: [String: Signal] = [:]

        /// Runs on every inbox change and once a second regardless — the
        /// derived Signals (stall, unanswered prompt, dead process) turn on
        /// the passage of time, not on an event arriving.
        func tick() {
            config.reloadIfChanged()
            store.ingest()
            // A `traffic-light cleanup` in another terminal. Serviced here
            // because this process owns `state.json` — it rewrites the file
            // from memory every couple of seconds, so anyone else editing it
            // would simply be overwritten. Deleting the request is the
            // acknowledgement the waiting command is watching for.
            if FileManager.default.fileExists(atPath: Paths.cleanupRequest.path) {
                store.sweep()
                // Persisted before the acknowledgement, not left to the next
                // beat: the command reads the session count the instant the
                // request file disappears, and `beat` is rate-limited, so the
                // ack could otherwise arrive ahead of the write it announces.
                store.persist()
                // Released before the acknowledgement too, because the command
                // may be about to delete the log and this process is holding
                // it open.
                store.log.release()
                try? FileManager.default.removeItem(at: Paths.cleanupRequest)
            }
            // A heartbeat, because `ingest` only persists when the inbox had
            // something in it. `snapshot.updated` is what every health check
            // reads as "is the daemon alive", and on a quiet afternoon nothing
            // arrives for minutes — so a perfectly healthy daemon reported
            // itself stale, in its own Settings window, with an orange dot.
            // Idle is the state this tool is *for*; it cannot be the state
            // that looks like a fault.
            store.beat()
            let names = Dictionary(
                config.current.attention.projects
                    .compactMap { rule -> (String, String)? in
                        guard let name = rule.displayName, !name.isEmpty else { return nil }
                        return (rule.id, name)
                    },
                uniquingKeysWith: { first, _ in first })
            let rows = Store.rows(from: store.snapshot, names: names)
            let aggregate = Signal.aggregate(rows.filter(\.reporting).map(\.signal))
            // Remember which projects exist, so Settings can offer one that is
            // not open right now. Writes at most once a minute, and at once
            // for a project never seen before.
            ProjectRoster.shared.note(rows.map(\.project))

            var transitions: [Transition] = []
            for row in rows where row.reporting && previous[row.sessionId] != row.signal {
                // A Session's first sighting is not a Transition; it would ring
                // the bell for every session that already existed at startup.
                if previous[row.sessionId] != nil {
                    transitions.append(Transition(sessionId: row.sessionId,
                                                  name: row.name, project: row.project,
                                                  to: row.signal,
                                                  note: row.note, text: row.text))
                }
                previous[row.sessionId] = row.signal
            }
            let seen = Set(rows.map(\.sessionId))
            previous = previous.filter { seen.contains($0.key) }

            // Resolved once, here, and handed to every Renderer. Each working
            // it out for itself is how a bell goes silent while the phone
            // still buzzes — the two would be reading the same config through
            // different code.
            let settings = config.current.attention
            let attention = AttentionState.resolve(now: Date(),
                                                   snooze: settings.snooze,
                                                   windows: settings.windows,
                                                   rules: settings.projects)

            for renderer in renderers {
                renderer.render(rows: rows, aggregate: aggregate,
                                transitions: transitions, attention: attention)
            }
        }

        try? FileManager.default.createDirectory(at: Paths.inbox, withIntermediateDirectories: true)

        if once {
            tick()
            return
        }

        let watcher = InboxWatcher(onChange: tick)
        watcher.start()

        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        tick()

        runLoop(headless: headless)
    }
}

/// Change detection degrades gracefully, by design. A kqueue vnode
/// source fires the instant a hook drops a file; the one-second timer in
/// `run` is the backstop that also drives time-based Signals, so losing the
/// watcher costs latency and nothing else.
final class InboxWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func start() {
        fd = open(Paths.inbox.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.onChange() }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}

/// `--headless`: no AppKit, redraws in place. The debug view, and what runs
/// over SSH or in a test.
final class TerminalRenderer: Renderer {
    private var last = ""

    func render(rows: [Row], aggregate: Signal, transitions: [Transition],
                attention: AttentionState) {
        let suffix = attention.global == .normal ? "" : "   \(dim)\(attention.global.rawValue)\(reset)"
        // Split the same way `traffic-light status` does. Listing sessions
        // without the hooks installed among the reporting ones puts rows under
        // a count that does not include them, and every one of them reads
        // `Idle` — which is indistinguishable from a session that is genuinely
        // idle, and the opposite of what "not connected" means.
        let reporting = rows.filter(\.reporting)
        let silent = rows.filter { !$0.reporting }
        var out = "\n" + TerminalRow.header(aggregate, count: reporting.count,
                                            suffix: suffix) + "\n\n"
        for row in reporting { out += TerminalRow.line(row) + "\n" }
        if reporting.isEmpty { out += "  \(dim)\(Wording.nothingConnected)\(reset)\n" }
        if !silent.isEmpty {
            out += "  \(dim)\(Wording.othersNotConnected(silent.count)): "
                + "\(silent.map(\.name).joined(separator: ", "))\(reset)\n"
        }
        guard out != last else { return }
        last = out
        print("\u{1B}[H\u{1B}[J" + out)
    }
}
