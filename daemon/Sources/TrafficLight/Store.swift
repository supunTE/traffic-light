import Foundation

/// Thresholds, all of them earned rather than guessed.
enum Thresholds {
    /// Measured over 57 236 gaps across 13 weeks: the false-red rate reaches
    /// 0 % at ≥1400 s. 1800 s buys margin.
    static let stall: Double = 1800

    /// A permission prompt fires no event and a denial fires
    /// nothing at all, so a tool still in flight is the only trace a blocked
    /// Session leaves. For tools that finish in milliseconds, outliving this
    /// means a human is being waited on.
    ///
    /// This was 45 s, chosen when the gap was the *only* evidence and a long
    /// `Bash` had to be given room to prove itself. It no longer is — the
    /// process table settles that case directly, so the wait was buying
    /// nothing but a light that stayed green while a dialog sat on screen.
    /// What is left to absorb is ingest lag and a `Read` of something large,
    /// which is seconds, not a minute.
    static let ask: Double = 10

    /// For tools that can legitimately run for a long time and spawn nothing
    /// we can see — a subagent, a web fetch, an MCP call. There is no way to
    /// tell those apart from a waiting prompt, so the light stays green far
    /// longer rather than crying wolf. A late amber is a missed minute; a
    /// false amber teaches you to ignore the light, which costs everything.
    static let askOpaque: Double = 600

    /// Sessions have been observed starting and ending 0.47 s
    /// apart at app launch. Without this the bar flickers on every launch.
    static let minAge: Double = 2

    /// How long a *living* session can say nothing before whatever it last
    /// said stops counting as a claim on anyone's attention.
    ///
    /// Neither of the other two clocks reaches this. The stall clock is paused
    /// by any turn that ends on you — correctly, since waiting for a human is
    /// not a hang — and the liveness check is happy because the process really
    /// is there. So a session you finished with on Friday went on holding the
    /// aggregate at Asking, and the menu bar is one dot: a single forgotten
    /// session is enough to make it wrong for everything.
    ///
    /// A working day, and unlike the others this is a judgement rather than a
    /// measurement. It has to clear an afternoon of meetings without demoting
    /// something you are in the middle of, and it has to be short enough that
    /// yesterday's leftovers are not still shouting this morning. Nothing is
    /// hidden when it expires — the row stays and says how long it has been
    /// quiet — which is what makes a wrong guess here cheap.
    static let dormant: Double = 8 * 3600
}

/// One row of what a renderer should show.
struct Row {
    /// What to put in front of a human. Built from the project directory, not
    /// from the registry's `name`: that one is `nameSource: "derived"` and its
    /// suffix changes on every app restart — one session has appeared as
    /// `traffic-light-ba`, `-89`, `-b0`, `-c8` and `-fb` in a single day.
    /// A label that renames itself is worse than no label.
    let name: String
    /// Directory basename, e.g. `traffic-light`.
    let project: String
    /// The title Claude Code shows for the conversation, when it has one.
    let title: String?
    let signal: Signal
    let note: String
    let age: Double?
    let sessionId: String
    let cwd: String?
    let text: String?
    /// The hook event behind `note`, for the tooltip.
    let rawNote: String
    /// False when Claude Code knows about this Session but no hook has ever
    /// reported from it — the plugin is not enabled in that project.
    let reporting: Bool

    /// What this session is *about*, falling back to where it is. Claude Code
    /// does not always have a title, and an empty top line reads worse than a
    /// repeated project name.
    var headline: String { title?.isEmpty == false ? title! : name }

    /// Where it is — omitted when it would only repeat the headline.
    var subtitle: String? { title?.isEmpty == false ? name : nil }

    /// Both, for renderers with only one line to spend.
    var oneLine: String { subtitle.map { "\(headline) · \($0)" } ?? headline }
}

/// The events this daemon speaks.
///
/// The inbox is a plain directory, so whatever runs the hook writes into it —
/// and other editors have adopted the same plugin layout closely enough to
/// pick this plugin up. One of them fires `sessionEnd`, `beforeSubmitPrompt`
/// and `stop`, sends no `cwd`, and registers no process anywhere. Its sessions
/// arrived unnameable and, with no pid to ask about, permanently red.
///
/// So the door is a *positive* test: a payload has to look like Claude Code's
/// to get in, rather than having to look like somebody else's to be turned
/// away. A vocabulary nobody has seen yet is refused without anyone having to
/// name it first, and this list stays true by being ours.
///
/// `DistressCall` is not Claude Code's — it is what `traffic-light broken`
/// writes — but it is this daemon's own, which is the same test.
enum HookVocabulary {
    static let known: Set<String> = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "Notification", "Stop", "PreCompact", "DistressCall",
    ]
}

final class Store {
    /// Owned by the Store because ingest is the only place every
    /// payload is in hand, and the only place their true order is known.
    let log: EventLog

    init(config: ConfigStore = ConfigStore()) {
        log = EventLog(config: config)
    }

    private(set) var snapshot = Snapshot()

    // MARK: Persistence

    static func loadSnapshot() -> Snapshot {
        guard let data = try? Data(contentsOf: Paths.state),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return Snapshot() }
        return snap
    }

    func load() { snapshot = Store.loadSnapshot() }

    /// Keeps `updated` fresh while nothing is happening.
    ///
    /// Rate-limited rather than written every tick: this runs once a second
    /// forever, and a file rewritten 86 400 times a day to say "still here" is
    /// a lot of disk for one timestamp. Two seconds is under every reader's
    /// staleness threshold and an order of magnitude fewer writes.
    func beat() {
        guard Date().timeIntervalSince1970 - snapshot.updated >= 2 else { return }
        // Pruned here as well as after ingest, because a session that dies
        // stops producing events — so the one moment it most needs collecting
        // is the moment nothing is arriving to trigger a collection. Left to
        // ingest alone, an abandoned session waited for an *unrelated* session
        // to do something before it could be cleared.
        prune()
        persist()
    }

    /// Written temp-then-rename so a reader never sees a half-written file,
    /// and 0600 because it holds prompt and assistant text.
    ///
    /// `heartbeat: false` writes the file without claiming the daemon is
    /// alive. `updated` is not a modification time — every health check reads
    /// it as *the daemon wrote this just now*, so a one-shot command touching
    /// it makes a daemon that died an hour ago look like it is running, for
    /// thirty seconds, in `doctor` and in the Settings window.
    func persist(heartbeat: Bool = true) {
        if heartbeat { snapshot.updated = Date().timeIntervalSince1970 }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // Written to a sibling and moved into place, rather than straight to
        // `Paths.state`: `.atomic` alone renames over the target, which is
        // atomic for a reader opening the path afresh but replaces the inode —
        // and `replaceItemAt` preserves it for anything holding the file open.
        let tmp = Paths.home.appending(path: "state.json.tmp")
        guard Paths.writePrivately(data, to: tmp) else { return }
        _ = try? FileManager.default.replaceItemAt(Paths.state, withItemAt: tmp)
    }

    // MARK: Ingest

    /// Drains the inbox in arrival order. The daemon owns this; nothing else
    /// may call it, or two processes would race to delete the same files.
    @discardableResult
    func ingest() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.inbox,
                                                      includingPropertiesForKeys: nil)
        else { return 0 }

        // Ordered by file modification time, not by the timestamp inside the
        // payload. The hook stamps `date +%s` — whole seconds — so a tool that
        // finishes inside one second gives its PreToolUse and PostToolUse the
        // same `at`, and sorting on that leaves their order to chance. Applying
        // the Post first makes its removeAll match nothing and the Pre is then
        // added, orphaning the entry forever.
        //
        // APFS records mtime in nanoseconds, so file order is the true arrival
        // order — and it costs the hook nothing, which matters more than
        // precision here.
        var events: [(event: HookEvent, url: URL, written: Double, data: Data)] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { try? fm.removeItem(at: url); continue }
            guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
                // Belt to the hook's braces. The hook renames into place now,
                // so nothing should ever be read half-written — but a file
                // that fails to decode *and* is younger than a second is far
                // more likely to be mid-write than malformed, and deleting it
                // is unrecoverable. Leave it; the next tick is a second away.
                let age = Date().timeIntervalSince1970
                    - ((try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate)?.timeIntervalSince1970 ?? 0)
                if age < 1 { continue }
                // Unparseable: drop it rather than let it wedge the inbox
                // forever — but say so in the log first. This is what a
                // payload shape changing under us looks like from in here,
                // and dropping it silently is how that goes unnoticed.
                log.unreadable(data)
                try? fm.removeItem(at: url); continue
            }
            let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)?.timeIntervalSince1970 ?? event.at
            // Not ours. Dropped here rather than folded in and sorted out
            // later, because a session built from a payload we do not
            // understand is a session nothing can ever answer questions about.
            guard HookVocabulary.known.contains(event.payload.hook_event_name) else {
                snapshot.ignored.note(event.payload.hook_event_name, at: written)
                try? fm.removeItem(at: url); continue
            }
            events.append((event, url, written, data))
        }
        events.sort { $0.written < $1.written }

        for entry in events {
            // Logged inside the sorted loop on purpose: the hook stamps whole
            // seconds, so `at` cannot order two events in the same second.
            // Line order here is true arrival order, and that is the one thing
            // the payloads themselves cannot tell a later reader.
            log.append(entry.data, written: entry.written)
            apply(entry.event)
            try? fm.removeItem(at: entry.url)
        }
        if !events.isEmpty { prune(); persist() }
        return events.count
    }

    /// A Session whose process is gone is history, and history does not belong
    /// in a file that is rewritten every second. Kept for an hour after its
    /// last event so a restart-in-progress is not mistaken for a death, and so
    /// a crash has time to be seen before it is swept up.
    private func prune() {
        let live = Store.liveRegistry()

        // Remember the process behind each Session while the registry is
        // there to tell us. It is the only way to answer "is this alive?"
        // on a tick where the registry file cannot be read.
        for (id, record) in live where snapshot.sessions[id] != nil {
            snapshot.sessions[id]?.pid = record.pid
            snapshot.sessions[id]?.pidStart = Processes.startTime(of: record.pid)
        }

        let cutoff = Date().timeIntervalSince1970 - 3600
        snapshot.sessions = snapshot.sessions.filter { id, s in
            // `!s.ended` used to keep a Session here regardless of age, and
            // that is what made dead ones immortal. A clean exit sets `ended`;
            // everything else — a crash, a `kill -9`, a SessionEnd whose name
            // this daemon did not recognise — does not, so the sessions
            // guaranteed to survive forever were precisely the ones nobody
            // could account for.
            //
            // Age is the honest test. A living Session is either in the
            // registry or answering on its pid; anything else is judged on
            // when it was last heard from, whatever it did or did not say on
            // the way out.
            Store.isLive(id, s, registry: live) || s.lastEvent > cutoff
        }
    }

    /// The state machine. Every branch here is backed by an
    /// observed hook fire, not by documentation.
    private func apply(_ event: HookEvent) {
        let p = event.payload
        let now = event.at
        var s = snapshot.sessions[p.session_id] ?? {
            var fresh = SessionState(sessionId: p.session_id)
            fresh.firstSeen = now
            return fresh
        }()

        s.lastEvent = now
        s.cwd = p.cwd ?? s.cwd
        // Newest wins, not first. `session_title` rides on some events and not
        // others, so `s.name ?? p.session_title` looked equivalent — but it
        // pinned the title to whatever the first titled event said, so a
        // renamed conversation kept its old label forever and a session whose
        // state was rebuilt could never pick a title back up.
        s.name = p.session_title ?? s.name
        s.transcriptPath = p.transcript_path ?? s.transcriptPath

        // A tool from a finished turn cannot be what this Session is blocked
        // on. Without this, anything that escapes the ledger — a denial, an
        // interrupt — lingers until the next prompt and ages into a false
        // Asking during a long agentic turn.
        if let current = p.prompt_id {
            s.inFlight.removeAll { $0.promptId != nil && $0.promptId != current }
        }
        s.closed = s.closed.filter { now - $0.value < 120 }

        func become(_ signal: Signal, _ note: String, raw: String) {
            if s.signal != signal.rawValue { s.since = now }
            s.signal = signal.rawValue
            s.note = note
            s.rawNote = raw
        }

        switch p.hook_event_name {
        case "SessionStart":
            // A resume or a compact continues an existing Session; only
            // `startup` is new. Compaction fires no SessionEnd at
            // all, so a Session must survive one.
            let source = p.source ?? "?"
            if source == "startup" { s.firstSeen = now }
            s.ended = false
            s.inFlight = []
            s.clockFrom = nil
            become(.idle, Wording.started(source), raw: "SessionStart:\(source)")

        case "SessionEnd":
            s.ended = true
            s.note = Wording.closed
            s.rawNote = "SessionEnd:\(p.reason ?? "?")"

        case "UserPromptSubmit":
            // A denied tool never gets a PostToolUse, so its
            // tool_use_id would sit unmatched forever. A new prompt proves the
            // human was present and dealt with whatever was pending.
            s.inFlight = []
            s.text = p.prompt
            s.clockFrom = now
            become(.working, Wording.thinking, raw: "UserPromptSubmit")

        case "PreToolUse":
            let tool = p.tool_name ?? "?"
            if let id = p.tool_use_id {
                if s.closed.removeValue(forKey: id) == nil {
                    s.inFlight.append(InFlight(id: id, tool: tool, at: now,
                                               promptId: p.prompt_id))
                }
                // else: its PostToolUse was applied first, so this call is
                // already over and must not enter the ledger at all.
            }
            // Pause the stall clock across a tool, or every
            // permission wait counts as a stall.
            s.clockFrom = nil
            if tool == "AskUserQuestion" {
                become(.asking, Wording.waitingForAnswer, raw: "PreToolUse:\(tool)")
            } else {
                become(.working, Wording.running(tool), raw: "PreToolUse:\(tool)")
            }

        case "PostToolUse":
            if let id = p.tool_use_id {
                let before = s.inFlight.count
                s.inFlight.removeAll { $0.id == id }
                // Nothing to remove means this arrived before its own
                // PreToolUse; remember it so the Pre can cancel itself.
                if s.inFlight.count == before { s.closed[id] = now }
            }
            // Only restart the clock once nothing is outstanding. The payload
            // gives us tool_use_id, so concurrent tools are tracked exactly
            // rather than assumed away.
            if s.inFlight.isEmpty { s.clockFrom = now }
            // A finished tool's duration flickers past and tells you nothing.
            // What matters is whether anything is still running: if something
            // is, name it; if not, Claude is deciding what to do next.
            let raw = "PostToolUse:\(p.tool_name ?? "?")"
                + (p.duration_ms.map { " \(Int($0))ms" } ?? "")
            if let next = s.inFlight.min(by: { $0.at < $1.at }) {
                become(.working, Wording.running(next.tool), raw: raw)
            } else {
                become(.working, Wording.thinking, raw: raw)
            }

        case "Notification":
            s.clockFrom = nil
            become(.asking, Wording.waitingForYou, raw: "Notification")

        case "Stop":
            s.inFlight = []
            s.backgroundTasks = p.background_tasks?.count ?? 0
            s.text = p.last_assistant_message
            if s.backgroundTasks > 0 {
                // The turn ended but work is still running.
                s.clockFrom = now
                become(.working, Wording.backgroundTasks(s.backgroundTasks),
                       raw: "Stop, \(s.backgroundTasks) background")
            } else if Wording.endsWithQuestion(s.text) {
                // A turn that ends on a question has stopped *on* you. Nothing
                // advances until you answer, which is Asking — the same state
                // as a permission prompt, reached by a different route. Green
                // here reads as "go and read it at your leisure", and the
                // session sits idle while you do.
                s.clockFrom = nil
                become(.asking, Wording.waitingForAnswer, raw: "Stop, ends on a question")
            } else {
                s.clockFrom = nil
                become(.done, Wording.yourTurn, raw: "Stop")
            }

        case "PreCompact":
            // Compaction runs long and silent, but it is bounded: a
            // SessionStart(compact) always follows. Observed gap: 105 s.
            s.clockFrom = nil
            become(.working, Wording.compacting,
                   raw: "PreCompact:\(p.trigger ?? "?")")

        case "DistressCall":
            // The only route to Broken that carries a human-readable reason.
            // It outranks whatever the Session was doing: Claude asked for
            // help explicitly, which is stronger evidence than any inference
            // the daemon makes on its own.
            s.inFlight = []
            s.clockFrom = nil
            become(.broken, p.reason ?? Wording.askedForHelp, raw: "DistressCall")

        default:
            s.note = p.hook_event_name
            s.rawNote = p.hook_event_name
        }

        snapshot.sessions[p.session_id] = s
    }

    // MARK: Resolve

    /// Facts plus the clock equals a Signal. Pure, and safe to call against a
    /// stale snapshot — which is what lets `status` work without a daemon.
    /// `names` maps a project's directory basename to the label the user gave
    /// it in Settings. Applied here rather than in each renderer, so the menu
    /// bar, the floating bar and the phone all get it from one place.
    ///
    /// It used to be read in exactly one branch of `Push.post`, and only when
    /// `hideSessionTitle` was also on — while the card promised "used
    /// everywhere, including on your phone". Typing a name and leaving the
    /// checkbox alone did nothing at all.
    static func rows(from snapshot: Snapshot, now: Double = Date().timeIntervalSince1970,
                     names: [String: String] = [:]) -> [Row] {
        let registry = liveRegistry()

        // Two Sessions in one project would both be called the same thing, so
        // only then is a disambiguator added — and it is the session id, which
        // is stable, rather than the registry's restart-dependent suffix.
        //
        // Counted over what will actually be *shown*, not over the snapshot.
        // Ended Sessions linger in the snapshot for an hour so a restart is
        // not mistaken for a death, and counting those made every project look
        // duplicated — so every row wore a suffix that is supposed to be rare.
        func willRender(_ id: String, _ s: SessionState) -> Bool {
            if registry[id] == nil && s.ended { return false }
            if s.firstSeen > 0, now - s.firstSeen < Thresholds.minAge { return false }
            return true
        }
        var projectCounts: [String: Int] = [:]
        for (id, s) in snapshot.sessions where willRender(id, s) {
            projectCounts[project(of: registry[id]?.cwd ?? s.cwd), default: 0] += 1
        }
        for (id, r) in registry where snapshot.sessions[id] == nil {
            projectCounts[project(of: r.cwd), default: 0] += 1
        }
        func label(_ cwd: String?, _ id: String) -> String {
            let name = project(of: cwd)
            return projectCounts[name, default: 0] > 1 ? "\(name) · \(id.prefix(4))" : name
        }

        var rows: [Row] = []
        for (id, s) in snapshot.sessions {
            let record = registry[id]

            // Absent from the registry is not the same as dead. Those files
            // are rewritten while a session runs, and a read that lands
            // mid-rewrite — or on a half-written file — yields nothing, which
            // made a perfectly healthy Session flash red for one tick and then
            // carry on. Red rings the bell and pushes at urgent priority, so a
            // single-tick blip is a phone buzz for nothing.
            //
            // The process itself is the authority. Ask it directly before
            // declaring a death.
            let pid = record?.pid ?? s.pid
            let live = isLive(id, s, registry: registry)
            let cwd = record?.cwd ?? s.cwd
            let name = label(cwd, id)

            var signal = s.resolved
            var note = s.note
            var raw = s.rawNote

            if !live {
                // The registry file is deleted on exit. Gone plus a SessionEnd
                // is a clean exit; gone without one is a death.
                if s.ended { continue }
                signal = .broken
                note = Wording.crashed
                raw = "no registry entry, process gone, no SessionEnd"
            } else if let waiting = blockedOn(s, pid: pid, now: now) {
                // The only trace a blocked Session leaves.
                signal = .asking
                note = Wording.needsPermission(waiting.tool, waiting: now - waiting.at)
                raw = "\(waiting.tool) unmatched \(Int(now - waiting.at))s"
            } else if let from = s.clockFrom, now - from > Thresholds.stall {
                signal = .broken
                note = Wording.stuck(for: now - from)
                raw = "stall clock \(Int(now - from))s"
            }

            // Alive, but silent for so long that whatever it last said is no
            // longer news. Demoted rather than dropped: the process is real
            // and may be holding real memory, so saying nothing about it would
            // trade a misleading row for an invisible one. Idle is the bottom
            // of the ranking, so it stops driving the aggregate; `rawNote`
            // keeps the state it came from, for the tooltip.
            if live, s.lastEvent > 0, signal != .idle,
               now - s.lastEvent > Thresholds.dormant {
                raw = "\(raw), dormant \(Int(now - s.lastEvent))s"
                signal = .idle
                note = Wording.dormant(for: now - s.lastEvent)
            }

            // Launch phantoms: seen starting and ending inside half a second.
            if s.firstSeen > 0, now - s.firstSeen < Thresholds.minAge { continue }

            rows.append(Row(name: names[project(of: cwd)] ?? name, project: project(of: cwd), title: s.name,
                            signal: signal, note: note,
                            age: s.lastEvent > 0 ? now - s.lastEvent : nil,
                            sessionId: id, cwd: cwd, text: s.text,
                            rawNote: raw, reporting: true))
        }

        // Sessions Claude Code knows about that we have never seen an event
        // for — the plugin is not enabled in that project. Counted, not hidden:
        // silently omitting them would make a half-installed setup look
        // complete, which is the failure this tool must never have.
        let known = Set(snapshot.sessions.keys)
        for (id, r) in registry where !known.contains(id) {
            rows.append(Row(name: names[project(of: r.cwd)] ?? label(r.cwd, id), project: project(of: r.cwd),
                            title: nil, signal: .idle,
                            note: Wording.notConnected, age: nil,
                            sessionId: id, cwd: r.cwd, text: nil,
                            rawNote: "no events seen", reporting: false))
        }

        rows.sort { ($0.signal.rank, $0.name) < ($1.signal.rank, $1.name) }
        return rows
    }

    /// Which tool, if any, this Session is stuck waiting on a human for.
    ///
    /// Judged across *every* in-flight tool, not just the oldest. A denied or
    /// interrupted tool leaves an entry that nothing ever closes — it clears
    /// only on the next `UserPromptSubmit` — so picking the oldest meant a
    /// Session busily running something new was judged on an orphan from ten
    /// minutes ago, and flashed amber while working perfectly.
    ///
    /// If the Session has spawned anything since a tool started, that tool is
    /// executing and the Session is fine regardless of what else is pending.
    ///
    /// A blocked Session is *silent*: a permission prompt fires
    /// no event, and a denial fires nothing either. So the question is not
    /// "is some tool call still open", which stale entries answer wrongly. It
    /// is "is the newest tool call also the last thing that happened".
    ///
    /// If anything at all has happened since — another tool starting, another
    /// finishing — the Session is not sitting at a prompt, whatever else is
    /// left open in the ledger. Thresholds and process checks only
    /// approximate that condition.
    private static func blockedOn(_ state: SessionState, pid: Int32?,
                                  now: Double) -> InFlight? {
        guard let newest = state.inFlight.max(by: { $0.at < $1.at }) else { return nil }

        // Something happened after this call began, so nothing is waiting.
        guard state.lastEvent - newest.at < 1 else { return nil }
        guard now - newest.at > threshold(for: newest.tool) else { return nil }

        // Claude Code spawns nothing until permission is granted, so a process
        // started since the call began means it is executing. This is what
        // separates a long test run from a prompt nobody has answered.
        if let pid, Processes.spawnedSomething(since: newest.at, of: pid) { return nil }

        return newest
    }

    /// Tools that can legitimately run for a long time and spawn nothing we
    /// can see get a much longer fuse, because for them there is genuinely
    /// nothing to measure. Everything else finishes in milliseconds, so
    /// outliving the short threshold can only mean a prompt.
    private static func threshold(for tool: String) -> Double {
        switch tool {
        case "Task", "WebFetch", "WebSearch": Thresholds.askOpaque
        default: tool.hasPrefix("mcp__") ? Thresholds.askOpaque : Thresholds.ask
        }
    }

    private static func project(of cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "unknown" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Everything the hourly grace period is still holding, dropped now.
    ///
    /// `prune` keeps a dead session for an hour so that a restart in progress
    /// is not mistaken for a death. That is the right default and the wrong
    /// answer when someone has looked at a stale row and decided it is stale —
    /// waiting out a timer you have already out-reasoned is how a tool teaches
    /// you to ignore it. Only sessions whose process is genuinely gone go;
    /// nothing living is touched, whatever it is doing.
    ///
    /// Does not persist: the caller decides, because the two callers disagree
    /// about the heartbeat. The daemon is alive and says so; the command is a
    /// visitor and must not.
    @discardableResult
    func sweep() -> Int {
        let live = Store.liveRegistry()
        let before = snapshot.sessions.count
        snapshot.sessions = snapshot.sessions.filter { id, s in
            Store.isLive(id, s, registry: live)
        }
        return before - snapshot.sessions.count
    }

    /// Is this Session's process still there?
    ///
    /// The registry answers it outright when the file can be read. When it
    /// cannot — those files are rewritten while a session runs, and a read
    /// landing mid-rewrite yields nothing — the remembered pid answers
    /// instead, which is what stops a healthy Session flashing red for a tick.
    ///
    /// The pid is only trusted alongside the start time captured with it.
    /// A pid outlives the process that held it and the kernel hands the number
    /// back out, so `kill(pid, 0)` on its own eventually says yes about a
    /// stranger — and a Session that died last week reads as alive because
    /// something unrelated inherited its number.
    ///
    /// A pid remembered before start times were recorded has no start time to
    /// check against. Those are believed, once: they are the state file as it
    /// was on upgrade, and they age out within the hour on their own.
    static func isLive(_ id: String, _ s: SessionState,
                       registry: [String: RegistryRecord]) -> Bool {
        if registry[id] != nil { return true }
        guard let pid = s.pid, isAlive(pid) else { return false }
        guard let remembered = s.pidStart else { return true }
        guard let actual = Processes.startTime(of: pid) else { return false }
        return abs(actual - remembered) < 1
    }

    /// sessionId → record, for interactive sessions whose process is alive.
    static func liveRegistry() -> [String: RegistryRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Paths.registry, includingPropertiesForKeys: nil) else { return [:] }

        var out: [String: RegistryRecord] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(RegistryRecord.self, from: data),
                  record.kind == "interactive",
                  isAlive(record.pid)
            else { continue }
            out[record.sessionId] = record
        }
        return out
    }

    /// Signal 0 tests existence without delivering anything. EPERM means the
    /// process exists but belongs to someone else, which still counts.
    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
