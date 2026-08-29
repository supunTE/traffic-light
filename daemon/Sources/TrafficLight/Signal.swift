import Foundation

let reset = "\u{1B}[0m"
let dim = "\u{1B}[2m"

/// The state of exactly one Session. The palette lives elsewhere; this owns the
/// vocabulary and the order.
enum Signal: String, CaseIterable {
    case broken = "Broken"
    case asking = "Asking"
    case done = "Done"
    case working = "Working"
    case idle = "Idle"

    /// The order: `Broken > Asking > Done > Working > Idle`.
    /// Lower rank wins when aggregating, because it is the more urgent claim
    /// on a human's attention.
    var rank: Int {
        switch self {
        case .broken: 0
        case .asking: 1
        case .done: 2
        case .working: 3
        case .idle: 4
        }
    }

    /// The Aggregate Signal: what a whole-screen renderer shows for everything
    /// at once. `Idle` when there is nothing alive to report.
    static func aggregate<S: Sequence<Signal>>(_ signals: S) -> Signal {
        signals.min { $0.rank < $1.rank } ?? .idle
    }

    /// Shape carries the meaning as well as colour. A menu bar dot is ~14pt on
    /// a background the user chose, and roughly one in twelve men cannot
    /// separate the red from the green — so the two Signals that mean *act now*
    /// differ in silhouette, not just hue.
    var symbolName: String {
        switch self {
        case .broken: "exclamationmark.triangle.fill"
        case .asking: "questionmark.circle.fill"
        case .done: "checkmark.circle.fill"
        // Working and Idle have no symbol: both are drawn rings, so their
        // size and position match by construction rather than by luck. A
        // symbol's ink sits inside a box of its own choosing, which is why
        // the turning arc and the idle circle never lined up.
        case .working: ""
        case .idle: ""
        }
    }

    /// The ntfy tag, which the phone renders as an emoji beside the title.
    ///
    /// A third rendering of the same vocabulary, and it follows `symbolName`
    /// deliberately: triangle, question mark, tick. That one exists because
    /// colour alone is not a distinction everybody can make, and a phone is
    /// further from the work than a menu bar is, not closer — so it is the
    /// last place that should collapse two states into one icon. This did:
    /// everything that was not Broken sent a bell, which meant *answer me now*
    /// and *read this whenever* arrived looking identical.
    var pushTag: String {
        switch self {
        case .broken: "rotating_light"
        case .asking: "question"
        case .done: "white_check_mark"
        // Neither is in the default push list, and neither should be — but
        // the list is configurable, so they need an icon rather than a crash.
        case .working, .idle: "bell"
        }
    }

    /// Terminal rendering, for `traffic-light status`.
    var ansi: String {
        switch self {
        case .broken: "\u{1B}[31m"
        case .asking: "\u{1B}[33m"
        case .done: "\u{1B}[32m"
        case .working: "\u{1B}[35m"
        case .idle: "\u{1B}[90m"
        }
    }
}

/// The terminal layout, in one place.
///
/// There are two terminal callers — `traffic-light status`, which prints once
/// and exits, and `daemon --headless`, which redraws in place — and they built
/// the same line independently. They had already drifted: `status` counted only
/// reporting sessions in its header while `--headless` counted every row, so
/// the same machine gave two different answers to "how many sessions" depending
/// on which command you ran.
enum TerminalRow {
    /// `● Asking   the name              12s  note`
    static func line(_ row: Row) -> String {
        let age = row.age.map { "\(Int($0))s" } ?? "–"
        let signal = row.signal.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        let name = row.oneLine.padding(toLength: max(28, row.oneLine.count),
                                       withPad: " ", startingAt: 0)
        return "  \(row.signal.ansi)●\(reset) \(row.signal.ansi)\(signal)\(reset) "
            + "\(name) \(dim)\(age.leftPadded(6))  \(row.note)\(reset)"
    }

    /// The header. `count` is the number of sessions the light is actually
    /// speaking for — sessions without the hooks installed are reported
    /// separately, and counting them here overstates what is being watched.
    static func header(_ aggregate: Signal, count: Int, suffix: String = "") -> String {
        "  \(aggregate.ansi)●\(reset)  \(aggregate.rawValue)   "
            + "\(dim)\(count) session(s)\(reset)\(suffix)"
    }
}
