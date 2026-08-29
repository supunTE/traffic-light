import Foundation

/// `~/Library/Application Support/traffic-light/config.json`, written with
/// defaults on first run so there is something to edit rather than something
/// to invent.
struct Config: Codable {
    struct Bell: Codable {
        var enabled = true
        /// Silence is a design choice, not an omission: `Working` and `Idle`
        /// have no sound because being told about them is the noise this tool
        /// exists to remove.
        var sounds: [String: String] = [
            Signal.broken.rawValue: "Basso",
            Signal.asking.rawValue: "Ping",
            Signal.done.rawValue: "Glass"
        ]
        /// Several sessions finishing together should ring once, not five
        /// times. The most urgent Transition in the window wins.
        var minIntervalSeconds: Double = 2
        /// 0–1. `NSSound` exposes this per sound, so it costs nothing to offer
        /// — and a chime you can only have at system volume is one people turn
        /// off rather than turn down.
        var volume: Double = 1

        /// Same reason as `Config`: one absent field must not discard the rest.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.lenient(.enabled) ?? enabled
            sounds = c.lenient(.sounds) ?? sounds
            minIntervalSeconds = c.lenient(.minIntervalSeconds) ?? minIntervalSeconds
            volume = c.lenient(.volume) ?? volume
        }

        init() {}
    }

    struct Push: Codable {
        /// Off until a topic exists. A push with no topic is not a push.
        var enabled = false
        var server = "https://ntfy.sh"
        var topic = ""
        /// Everything that means the Session has stopped — whether it is
        /// blocked, dead, or simply finished. `Done` is here because the point
        /// of leaving the desk is not being told only about problems: work
        /// that is ready to read is why you would come back. It pushes at the
        /// lowest priority of the three, so it arrives without insisting.
        ///
        /// `Working` and `Idle` are not in this list and should not be. Being
        /// notified of progress is the noise this tool exists to remove.
        var signals: [String] = [Signal.broken.rawValue, Signal.asking.rawValue,
                                 Signal.done.rawValue]
        /// An ntfy topic name is its only password, and `Stop` payloads carry
        /// the entire assistant message. Off by default, deliberately.
        var includeText = false
        var minIntervalSeconds: Double = 10
        /// Per-Signal override of how insistently the phone announces it.
        /// Empty means the built-in ranking, which is what almost everyone
        /// should leave it as.
        var priorities: [String: String] = [:]

        /// Same reason as `Config`: one absent field must not discard the rest.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.lenient(.enabled) ?? enabled
            server = c.lenient(.server) ?? server
            topic = c.lenient(.topic) ?? topic
            signals = c.lenient(.signals) ?? signals
            includeText = c.lenient(.includeText) ?? includeText
            minIntervalSeconds = c.lenient(.minIntervalSeconds) ?? minIntervalSeconds
            priorities = c.lenient(.priorities) ?? priorities
        }

        init() {}
    }

    /// The daemon sees every payload and, without this, keeps none
    /// of them — so anything that needs *what happened over time* stays
    /// unanswerable however long you wait.
    ///
    /// **A developer facility, off by default.** It answers questions about
    /// Traffic Light rather than questions a user has: whether Claude Code's
    /// ~900 s hang can be detected, whether a payload's shape has drifted, how
    /// long a permission prompt sat there. None of that changes what the light
    /// does today, and none of it is worth writing a file on someone's disk
    /// for without asking. It is not in Settings for the same reason `icon` is
    /// not in `--help`.
    ///
    /// Turn it on by hand in `config.json` when you are working on one of
    /// those questions. A log switched on after you go looking is an empty
    /// file, so it has to be on *before* the thing you want to catch — which
    /// is exactly why it is a deliberate act rather than a default.
    struct Log: Codable {
        var enabled = false
        /// **Off by default, and the important default in this struct.**
        /// `UserPromptSubmit` carries everything typed and `Stop` the entire
        /// reply, so with this on the file holds more of the day's thinking
        /// than anything else on disk. Nothing the log exists for reads the
        /// words — the hang is a timing gap, drift is a shape, blocking time
        /// is arithmetic — so the text is pure residue unless you are actively
        /// debugging and want it. Sizes are recorded either way.
        var includeText = false
        /// Rotated at this size keeping one generation, so the ceiling is 2×
        /// and it can never quietly eat the disk.
        ///
        /// 16 MB is roughly 25 000 events with the text dropped — about a
        /// week of ordinary use, a fortnight counting the rotated generation,
        /// and far more than any of the questions this log exists for needs.
        /// The first ceiling was 128 MB, which was not a decision so much as
        /// a round number: nobody who switches on a debug log to chase a
        /// timing gap wants a quarter of a gigabyte of it, and by the time
        /// the old ceiling was reached the beginning would be months stale.
        var maxBytes = 16 * 1024 * 1024

        /// Same reason as `Config`: one absent field must not discard the rest.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.lenient(.enabled) ?? enabled
            includeText = c.lenient(.includeText) ?? includeText
            maxBytes = c.lenient(.maxBytes) ?? maxBytes
        }

        init() {}
    }

    /// Quiet hours, the menu snooze, and per-project rules.
    struct Attention_: Codable {
        var windows: [QuietWindow] = []
        var snooze: Snooze?
        var projects: [ProjectRule] = []

        /// Same reason as `Config`: one absent field must not discard the rest.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            windows = c.lenient(.windows) ?? windows
            projects = c.lenient(.projects) ?? projects
            snooze = c.lenient(.snooze)
        }

        init() {}
    }

    /// The floating bar, which is draggable and can therefore end
    /// up under the notch or on a monitor that is no longer attached.
    struct Bar: Codable {
        var visible = true
        /// Point size of the bulb. The bar sizes itself to it.
        var size: Double = 22
        /// A row instead of a column, with each session's name under its bulb
        /// rather than beside it. Vertical by default because the bar lives in
        /// a screen corner, where a column has somewhere to grow and a row
        /// runs into the middle of the display.
        var horizontal = false

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            visible = c.lenient(.visible) ?? visible
            size = c.lenient(.size) ?? size
            horizontal = c.lenient(.horizontal) ?? horizontal
        }

        init() {}
    }

    var bell = Bell()
    var push = Push()
    var log = Log()
    var attention = Attention_()
    var bar = Bar()

    /// Every section and every field is optional on the way in, and a missing
    /// one keeps its default.
    ///
    /// This is not tidiness. Synthesised decoding throws on an absent key even
    /// where the property has a default, and `load()` answers a throw by
    /// writing a fresh config — so **adding one field to this struct silently
    /// reset every existing user's settings**, push topic included, and their
    /// phone went quiet with nothing to see. The same shape as the empty-topic
    /// bug, arriving from the other direction.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bell = c.lenient(.bell) ?? Bell()
        push = c.lenient(.push) ?? Push()
        log = c.lenient(.log) ?? Log()
        attention = c.lenient(.attention) ?? Attention_()
        bar = c.lenient(.bar) ?? Bar()
    }

    init() {}

    /// Every sound macOS ships. The preview panel offers exactly these,
    /// because `NSSound(named:)` silently returns nil for anything else and a
    /// bell that never rings looks identical to a session that never changed.
    static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    static func load() -> Config {
        if let data = try? Data(contentsOf: Paths.config),
           var config = try? Config.decoder().decode(Config.self, from: data) {
            // Backfill, because generating only on first write reaches nobody
            // who already ran the daemon once. Such a config keeps an empty
            // topic forever, and an empty topic makes Push return without
            // sending or complaining — push that looks configured and is
            // silent. Costs nothing: the topic is unused until enabled.
            if config.push.topic.isEmpty {
                config.push.topic = Config.freshTopic()
                config.write()
            }
            // Write the file back when it does not already contain every
            // setting. Leniency means an upgrade no longer *breaks* an old
            // config, but it would leave the new keys invisible — and a
            // setting you cannot see in the file is a setting you do not know
            // you have. Converges after one pass: the next load re-encodes to
            // the same bytes and writes nothing.
            if let normalised = config.encoded(), normalised != data { config.write() }
            return config
        }
        var fresh = Config()
        // Generated now, not left blank. On ntfy the topic name is the only
        // access control, so it has to be unguessable — and asking someone to
        // invent one at setup time gets you `traffic-light` or their own name.
        // Push stays disabled, so writing it costs nothing until it is wanted.
        fresh.push.topic = Config.freshTopic()
        fresh.write()
        return fresh
    }

    /// 20 characters from a 36-symbol alphabet: ~10^31 possibilities, which is
    /// not brute-forceable against a public server that rate-limits.
    static func freshTopic() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "traffic-light-" + String((0..<20).map { _ in alphabet.randomElement()! })
    }

    /// The exact bytes `write` would produce, so a caller can tell whether the
    /// file on disk is already current.
    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Unix seconds, like every other timestamp this project writes.
        // Foundation's default for `Date` is seconds since 2001, so a snooze
        // written that way reads as a date in 2057 to anything that assumes
        // the epoch the rest of the file uses — including a human editing it.
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(self)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    func write() {
        guard let data = encoded() else { return }
        Paths.writePrivately(data, to: Paths.config)
    }
}

/// Holds the current config and notices when the file on disk changes, so
/// editing `config.json` — or changing a sound in the preview panel — takes
/// effect without restarting the daemon.
final class ConfigStore {
    private(set) var current: Config
    private var stamp: Date?

    init() {
        current = Config.load()
        stamp = ConfigStore.modified()
    }

    /// Cheap enough to call every tick: one stat, and a read only on change.
    @discardableResult
    func reloadIfChanged() -> Bool {
        let now = ConfigStore.modified()
        guard now != stamp else { return false }
        stamp = now
        current = Config.load()
        return true
    }

    private static func modified() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: Paths.config.path)[.modificationDate] as? Date
    }
}
