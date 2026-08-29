import Foundation

enum Paths {
    /// Application Support, not `~/.claude/`, deliberately. State
    /// survives `~/.claude` being wiped and can never be mistaken for
    /// something Claude Code itself wrote.
    static let home: URL = {
        if let override = ProcessInfo.processInfo.environment["TRAFFIC_LIGHT_HOME"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/traffic-light")
    }()

    static var inbox: URL { home.appending(path: "inbox") }
    static var state: URL { home.appending(path: "state.json") }
    static var config: URL { home.appending(path: "config.json") }

    /// Every project the daemon has seen, so the Projects page is not limited
    /// to whatever happens to be running. Its own file: `state.json` has the
    /// opposite lifetime and `config.json` belongs to the human.
    static var projects: URL { home.appending(path: "projects.json") }

    /// `state.json` is a snapshot rewritten every second, so every
    /// question about what happened *over time* is unanswerable — a hang that
    /// fires no hook, a payload whose shape drifted, how long a prompt sat
    /// unanswered. This is the same events, kept.
    static var events: URL { home.appending(path: "events.jsonl") }
    static var eventsPrevious: URL { home.appending(path: "events.1.jsonl") }
    /// Written by `traffic-light cleanup`, deleted by the daemon once it has
    /// swept. A file rather than a signal or a socket: the daemon already
    /// watches this directory every tick, the request survives a daemon that
    /// is momentarily busy, and there is nothing to tear down if either side
    /// dies mid-way.
    static var cleanupRequest: URL { home.appending(path: "cleanup.request") }

    /// Read-only input. Traffic Light never writes here. Overridable for the
    /// same reason `home` is: the interesting cases are the ones where this
    /// directory is incomplete, and they cannot be staged against the real one
    /// without interfering with live sessions.
    static let registry: URL = {
        if let override = ProcessInfo.processInfo.environment["TRAFFIC_LIGHT_REGISTRY"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/sessions")
    }()

    /// A path as a human should read it, with the home directory back to `~`.
    ///
    /// Not cosmetic. `doctor` output is what people paste into a bug report,
    /// and the absolute form carries their account name into it.
    ///
    /// Anchored to the front and cut at a path separator, because a plain
    /// substring replace is wrong in two ways that both produce a path no
    /// longer naming the same file: a home directory appearing again deeper in
    /// the path is replaced too, and a sibling whose name merely begins with
    /// the same characters — `/Users/alicextra` beside `/Users/alice` — loses
    /// its first component. A path outside the home directory is returned
    /// unchanged, which is what `TRAFFIC_LIGHT_HOME` pointing elsewhere should
    /// look like.
    ///
    /// The same source as `home` above, so the one file that decides where
    /// things live also decides how they read.
    static func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Every file this project writes into `home` goes through here, except
    /// the event log, which holds its own append handle and sets the same mode
    /// itself.
    ///
    /// Three of them hold something private — prompt and assistant text in
    /// `state.json`, the ntfy topic in `config.json`, the names of directories
    /// you work in in `projects.json` — so everything written here is 0600
    /// rather than leaving the mode to be remembered at each call site.
    /// `cleanup.request` carries nothing, and costs nothing to treat the same
    /// way. Atomic because a reader polls these on a timer and must never catch
    /// a half file.
    ///
    /// The mode is set *after* the write on purpose: `.atomic` writes to a
    /// temporary file and renames it over the target, so permissions set on the
    /// old file do not survive, and the window between the two is a file that
    /// exists but has not been named yet.
    @discardableResult
    static func writePrivately(_ data: Data, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
        return true
    }
}

// MARK: - What a hook drops in the inbox

/// Decodes any JSON value without inspecting it. `background_tasks` has an
/// undocumented element shape and we only ever need its count.
struct Opaque: Codable {
    init(from decoder: Decoder) throws {}
    func encode(to encoder: Encoder) throws {}
}

/// Every field Claude Code writes is undocumented and may change shape without
/// warning — `procStart` is a formatted date string where a timestamp would be
/// the obvious choice, and that mismatch alone was once enough to make every
/// Session read as `Broken`. So an optional field that arrives as the wrong
/// type costs that one field, never the whole record.
extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key, _ type: T.Type = T.self) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

struct HookEvent: Decodable {
    let at: Double
    let payload: Payload

    struct Payload: Decodable {
        let hook_event_name: String
        let session_id: String
        let cwd: String?
        let transcript_path: String?
        let session_title: String?

        /// `startup` | `resume` | `compact` — and only `startup` means a new
        /// Session. `clear` is presumed but never observed.
        let source: String?
        let reason: String?
        let trigger: String?

        let tool_name: String?
        let tool_use_id: String?
        let duration_ms: Double?

        /// Shared by every event in one user turn. What lets a tool call from
        /// a finished turn be recognised as no longer relevant.
        let prompt_id: String?

        /// A turn can end with work still running — that is Working, not Done.
        let background_tasks: [Opaque]?

        let prompt: String?
        let last_assistant_message: String?

        enum CodingKeys: String, CodingKey {
            case hook_event_name, session_id, cwd, transcript_path, session_title
            case source, reason, trigger, tool_name, tool_use_id, duration_ms
            case prompt_id, background_tasks, prompt, last_assistant_message
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Only these two are load-bearing: an event with no name or no
            // session cannot be folded into anything and deserves to fail.
            hook_event_name = try c.decode(String.self, forKey: .hook_event_name)
            session_id = try c.decode(String.self, forKey: .session_id)

            cwd = c.lenient(.cwd)
            transcript_path = c.lenient(.transcript_path)
            session_title = c.lenient(.session_title)
            source = c.lenient(.source)
            reason = c.lenient(.reason)
            trigger = c.lenient(.trigger)
            tool_name = c.lenient(.tool_name)
            tool_use_id = c.lenient(.tool_use_id)
            duration_ms = c.lenient(.duration_ms)
            prompt_id = c.lenient(.prompt_id)
            background_tasks = c.lenient(.background_tasks)
            prompt = c.lenient(.prompt)
            last_assistant_message = c.lenient(.last_assistant_message)
        }
    }
}

// MARK: - What Claude Code publishes about itself

/// `~/.claude/sessions/<pid>.json`. Undocumented, and the file disappears the
/// moment the process exits — which is why a name must be captured on first
/// sight or lost forever.
struct RegistryRecord: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String?
    let name: String?
    let kind: String?
    /// A formatted local date — `"Fri Aug  7 13:26:11 2026"` — not a timestamp.
    /// Kept as written, and unused. The pid-reuse guard this was once meant to
    /// become reads the kernel's own start time instead: parsing a localised
    /// date string to compare against a clock is work, and every step of it is
    /// a way to be wrong about whether a session is alive.
    let procStart: String?

    enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, name, kind, procStart
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = c.lenient(.cwd)
        name = c.lenient(.name)
        kind = c.lenient(.kind)
        procStart = c.lenient(.procStart)
    }
}

// MARK: - Derived state

struct InFlight: Codable {
    let id: String
    let tool: String
    let at: Double
    /// Which turn it belongs to. An entry from a finished turn cannot be what
    /// the Session is currently blocked on.
    var promptId: String?
}

/// One Session's accumulated facts. Deliberately *facts*, not conclusions:
/// everything time-dependent (stall, liveness, an unanswered prompt) is
/// derived at render time, so a stale state file still yields a truthful light.
struct SessionState: Codable {
    var sessionId: String
    var signal: String = Signal.idle.rawValue
    var since: Double = 0
    var name: String?
    var cwd: String?
    var pid: Int32?

    /// When `pid` started. Without it a remembered pid is not an identity:
    /// pids are reused, so a session that died days ago goes on looking alive
    /// the moment something else is handed its number.
    var pidStart: Double?
    var firstSeen: Double = 0
    var lastEvent: Double = 0
    var inFlight: [InFlight] = []

    /// Tool calls whose `PostToolUse` was applied before their `PreToolUse`,
    /// so the Pre can cancel itself instead of becoming an orphan.
    ///
    /// The hook stamps whole seconds, so a tool finishing inside one second
    /// gives both events the same timestamp and their order is whatever the
    /// filesystem hands back. Ordering by file mtime fixes it in the normal
    /// case; this makes the fold correct even when it does not.
    var closed: [String: Double] = [:]

    /// When the stall clock started running, or nil while it is paused.
    var clockFrom: Double?
    var backgroundTasks: Int = 0
    var ended: Bool = false
    var transcriptPath: String?

    /// Why the Signal is what it is, in plain English. Shown everywhere.
    var note: String = "-"

    /// The hook event that produced it, verbatim. Never shown by default, kept
    /// for the tooltip — when the light is wrong this is the first thing worth
    /// knowing, and the friendly wording has thrown it away.
    var rawNote: String = "-"

    /// The last assistant message or prompt. Stored on-device for the
    /// per-session rows the floating bar shows, and never pushed off the machine
    /// unless the config explicitly opts in — an ntfy topic name is its only
    /// password.
    var text: String?

    var resolved: Signal { Signal(rawValue: signal) ?? .idle }
}

struct Snapshot: Codable {
    var updated: Double = 0
    var sessions: [String: SessionState] = [:]

    init() {}

    /// Decoded field by field, leniently, for the same reason every other type
    /// read off disk is.
    ///
    /// The synthesised decoder is all-or-nothing: a non-optional property
    /// whose key is missing throws, and one throw here discards *every
    /// session*. Adding `ignored` below was enough to do it — every
    /// `state.json` written before it existed lacks the key, so the first run
    /// of the new build would have read the file, thrown, and started from an
    /// empty snapshot. Every session on the machine would have looked new.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updated = c.lenient(.updated) ?? 0
        sessions = c.lenient(.sessions) ?? [:]
        ignored = c.lenient(.ignored) ?? Ignored()
    }

    /// Payloads turned away at the door. Counted rather than discarded in
    /// silence: the filter is a positive test against this daemon's own
    /// vocabulary, so the day Claude Code adds an event name is the day
    /// something starts being dropped — and a count in `doctor` is how that
    /// gets noticed instead of quietly changing what the light knows.
    var ignored = Ignored()
}

/// What the ingest filter refused, in the least detail that is still useful.
struct Ignored: Codable {
    var count: Int = 0
    var lastName: String?
    var lastAt: Double = 0

    init() {}

    mutating func note(_ name: String, at when: Double) {
        count += 1
        lastName = name
        lastAt = when
    }

    /// Same leniency as everything else read from disk: a field added later
    /// must not discard a file written by an older build.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = c.lenient(.count) ?? 0
        lastName = c.lenient(.lastName)
        lastAt = c.lenient(.lastAt) ?? 0
    }
}

/// What the About page shows.
///
/// Read from the bundle when there is one, so the app can never disagree with
/// its own `Info.plist` — that plist is generated by `install.sh` from
/// `package.json`, which makes the npm manifest the single source for a
/// release. The literal is the fallback for the bare CLI binary, which has no
/// bundle to ask.
enum Version {
    static let current: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
}
