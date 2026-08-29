import Foundation

/// How much of your attention Traffic Light is currently allowed.
///
/// Two named levels rather than a set of switches the user assembles, because
/// "muted chimes, silent push, bar hidden" is three questions to answer every
/// time and one answer to give once. Each level is a complete behaviour.
enum Attention: String, Codable, CaseIterable {
    /// Everything works. The default, and what most of the day is.
    case normal = "Normal"

    /// Nothing makes a sound, and nothing is hidden. Push still reaches the
    /// phone at ntfy's lowest priority — no buzz, but it is in the list when
    /// you pick the phone up, so an hour of silence costs you nothing you
    /// cannot catch up on.
    case quiet = "Quiet"

    /// Nothing is sent and nothing is shown. The floating bar disappears and
    /// the menu bar carries a crossed circle instead of a Signal, so red is
    /// invisible too.
    ///
    /// Named honestly on purpose. This is a blindfold, not a softer Quiet, and
    /// somebody enabling it should not have to discover that afterwards.
    case offDuty = "Off duty"

    /// Louder wins when two claims overlap — a quiet window inside an off-duty
    /// snooze stays off duty. Never the other way around: a setting that made
    /// the tool *noisier* than the strictest thing you asked for would be a
    /// setting you stop trusting.
    var rank: Int {
        switch self {
        case .normal: 0
        case .quiet: 1
        case .offDuty: 2
        }
    }

    static func strictest<S: Sequence<Attention>>(_ levels: S) -> Attention {
        levels.max { $0.rank < $1.rank } ?? .normal
    }

    var chimesAllowed: Bool { self == .normal }
    var pushAllowed: Bool { self != .offDuty }
    /// `Quiet` still delivers, at the tier that does not buzz.
    var forcesLowestPriority: Bool { self == .quiet }
    var barVisible: Bool { self != .offDuty }
    var showsSignalInMenuBar: Bool { self != .offDuty }
    var dimsMenuBar: Bool { self == .quiet }
}

/// One recurring stretch of the week at a given Attention.
///
/// Days are 1–7, Sunday-first, matching `Calendar.component(.weekday:)` so no
/// conversion is needed at the only place it is read.
struct QuietWindow: Codable, Identifiable {
    /// Every field is optional on the way in, and a missing one keeps its
    /// default — including the id, which gets a fresh one.
    ///
    /// Synthesised decoding made `id` required, and `Attention_` decodes the
    /// whole array leniently, so **one window missing an id emptied every
    /// window** — and `Config.load`'s normalise-on-load then wrote the
    /// deletion back to disk. Verified: two windows in, one of them valid, one
    /// missing an id; zero windows on disk one tick later. The same bug
    /// `Config`'s own decoder was written to fix, one level further down.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id) ?? UUID()
        days = c.lenient(.days) ?? days
        startMinute = c.lenient(.startMinute) ?? startMinute
        endMinute = c.lenient(.endMinute) ?? endMinute
        level = c.lenient(.level) ?? level
        enabled = c.lenient(.enabled) ?? enabled
    }

    init() {}

    var id = UUID()
    var days: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    /// Minutes from midnight, so a window is two integers and comparing them
    /// needs no date arithmetic and no time zone.
    var startMinute: Int = 22 * 60
    var endMinute: Int = 8 * 60
    var level: Attention = .quiet
    var enabled = true

    /// Whether this window covers a given moment.
    ///
    /// `22:00 → 08:00` is the ordinary case and it crosses midnight, so
    /// containment is deliberately not `start <= now < end`. When it wraps,
    /// the window is the union of two pieces — and **the day is matched
    /// against the day the window began**, not the day it is now. A Friday
    /// night window still applies at 02:00 on Saturday; asking "is today
    /// Saturday?" would silence the wrong night.
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, !days.isEmpty else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute
        else { return false }
        let now = hour * 60 + minute

        if startMinute == endMinute { return days.contains(weekday) }   // all day

        if startMinute < endMinute {
            return days.contains(weekday) && now >= startMinute && now < endMinute
        }
        // Wrapped. Before the end time belongs to yesterday's window.
        if now < endMinute {
            let yesterday = weekday == 1 ? 7 : weekday - 1
            return days.contains(yesterday)
        }
        return days.contains(weekday) && now >= startMinute
    }
}

/// A snooze taken from the menu: one level, until one moment.
///
/// `until` is absent for "until I turn it back on", which is the only form
/// that cannot expire on its own — and therefore the one the dimmed bulb and
/// the crossed circle exist to keep visible.
struct Snooze: Codable, Equatable {
    var level: Attention
    var until: Date?

    func active(at now: Date) -> Bool {
        guard let until else { return true }
        return now < until
    }
}

/// What a project asked for on its own behalf, plus how it should be named.
struct ProjectRule: Codable, Identifiable {
    /// Same reason as `QuietWindow`: a rule missing its id used to take every
    /// other rule with it. A rule with no id names no project, so it is the
    /// one field without a usable default — it decodes to the empty string and
    /// matches nothing, which costs that rule alone.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id) ?? ""
        displayName = c.lenient(.displayName)
        hideSessionTitle = c.lenient(.hideSessionTitle) ?? hideSessionTitle
        level = c.lenient(.level) ?? level
    }

    init(id: String) { self.id = id }

    /// The project directory's basename, which is what `Row.project` carries.
    var id: String
    /// Shown instead of the directory name — `acme-platform-revamp-acme-api`
    /// is a path, not a label.
    var displayName: String?
    /// Send only the project name, never the conversation title. The title is
    /// the part of a row that travels to the phone, so this is a privacy
    /// control before it is a tidiness one.
    var hideSessionTitle = false
    var level: Attention = .normal
}

/// Everything that decides how loud Traffic Light may currently be, resolved in
/// one place so no renderer has to work it out for itself.
///
/// Renderers ask this and obey. Putting the resolution behind one type is what
/// keeps "the bell is silent but the phone still buzzed" from being possible.
struct AttentionState {
    let global: Attention
    let perProject: [String: Attention]

    func level(forProject project: String?) -> Attention {
        guard let project, let rule = perProject[project] else { return global }
        return Attention.strictest([global, rule])
    }

    /// Snooze first because it is the deliberate act — someone who just asked
    /// for silence should get it whatever the schedule says. Windows then add
    /// their claim, and the strictest wins.
    static func resolve(now: Date,
                        snooze: Snooze?,
                        windows: [QuietWindow],
                        rules: [ProjectRule],
                        calendar: Calendar = .current) -> AttentionState {
        var claims: [Attention] = []
        if let snooze, snooze.active(at: now) { claims.append(snooze.level) }
        for window in windows where window.contains(now, calendar: calendar) {
            claims.append(window.level)
        }
        let global = Attention.strictest(claims)
        // `uniquingKeysWith`, never `uniqueKeysWithValues`: the latter *traps*
        // on a repeated key, and this runs on every tick. Two rules sharing an
        // id — trivial to produce by copying a block in the config file the
        // README invites people to edit — killed the daemon one second into
        // every restart, which with KeepAlive is a crash loop with no message.
        // The stricter of the two wins, which is the same rule every other
        // collision here follows.
        let perProject = Dictionary(
            rules.filter { $0.level != .normal }.map { ($0.id, $0.level) },
            uniquingKeysWith: { Attention.strictest([$0, $1]) })
        return AttentionState(global: global, perProject: perProject)
    }
}
