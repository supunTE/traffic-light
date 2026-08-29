import Foundation

/// Every project the daemon has ever seen, and when it last saw one.
///
/// The Projects page used to list `live.projects ∪ projects with a rule`, so a
/// project you were not running right now was simply not there — you could
/// only configure a project while a session in it happened to be open, and a
/// row you had set to defaults vanished the moment you closed the terminal.
/// Settings you cannot find are settings you do not have.
///
/// Its own file rather than a corner of an existing one. `state.json` is a
/// snapshot of what is true this second and is rewritten constantly, which is
/// the opposite lifetime; `config.json` is what the human wrote, and a list
/// the daemon maintains behind their back does not belong in a file they are
/// invited to edit.
///
/// Not actor-isolated, and does not need to be: the only two callers are the
/// daemon's tick and the Settings window, both of which run on the main thread
/// — the tick because it drives AppKit renderers, the window because it is a
/// window. Marking it `@MainActor` only moved that fact into a compiler error
/// at the tick, which is nonisolated for the same reason everything else in
/// this daemon is.
final class ProjectRoster {
    static let shared = ProjectRoster()

    /// id → last seen, unix seconds, like every other timestamp here.
    private(set) var seen: [String: Double]
    private var lastWrite: Double = 0

    /// Enough to cover every project anyone is really moving between, few
    /// enough that the page stays readable. Anything with a rule is exempt —
    /// a rule is the user saying this one matters.
    private let keep = 40
    /// Projects untouched for this long are dropped whatever the count.
    ///
    /// The cap alone prunes by *rank*, not by age, so a directory visited once
    /// in March held its place indefinitely as long as there were fewer than
    /// forty — and the page is meant to answer "which of my projects", not
    /// "everywhere this daemon has ever run". Two months is long enough to
    /// cover a project you return to between releases. Anything with a rule is
    /// exempt here too: a rule is the user saying this one matters, and that
    /// outranks a clock.
    private let forgetAfter: Double = 60 * 86_400
    /// One write a minute at most. This is called every tick, and the whole
    /// point of the file is that it survives a restart, not that it is
    /// accurate to the second.
    private let writeEvery: Double = 60

    private init() {
        seen = ProjectRoster.read()
    }

    /// Called from the daemon's tick with whatever is running now.
    func note(_ ids: [String]) {
        let now = Date().timeIntervalSince1970
        var changed = false
        for id in ids where !id.isEmpty {
            // New arrivals are worth writing immediately: a project seen for
            // the first time is exactly the one someone is about to go and
            // configure.
            if seen[id] == nil { changed = true }
            seen[id] = now
        }
        guard !seen.isEmpty else { return }
        if changed || now - lastWrite >= writeEvery { write(now: now) }
    }

    /// Drop one by hand. The roster fills itself, so it needs a way out that
    /// is not "wait forty projects".
    func forget(_ id: String) {
        guard seen.removeValue(forKey: id) != nil else { return }
        write(now: Date().timeIntervalSince1970)
    }

    /// Most recently seen first, with anything currently running or carrying a
    /// rule guaranteed present even if the file has never heard of it.
    func known(live: [String], ruled: Set<String>) -> [String] {
        var merged = seen
        let now = Date().timeIntervalSince1970
        for id in live { merged[id] = now }
        for id in ruled where merged[id] == nil { merged[id] = 0 }
        return merged.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.map(\.key)
    }

    // MARK: disk

    private func write(now: Double) {
        lastWrite = now
        // Prune before writing, not on read: a file that grows without bound
        // is still unbounded however politely it is displayed.
        //
        // Read once and used by both passes: the config is a file, and the
        // two rules here are the same rule — a project with a rule is kept,
        // whether it is age or the cap that came for it.
        let ruled = Set(Config.load().attention.projects.map(\.id))
        // `at == 0` is a project that only exists because it has a rule; it
        // has never been seen, so an age test would retire it immediately.
        seen = seen.filter { id, at in
            ruled.contains(id) || at == 0 || now - at < forgetAfter
        }
        if seen.count > keep {
            let expendable = seen.filter { !ruled.contains($0.key) }
                .sorted { $0.value > $1.value }
            // Everything with a rule stays whatever the count; the rest fill
            // what is left of the allowance, newest first.
            let allowance = max(0, keep - (seen.count - expendable.count))
            for entry in expendable.dropFirst(allowance) {
                seen.removeValue(forKey: entry.key)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(seen) else { return }
        Paths.writePrivately(data, to: Paths.projects)
    }

    private static func read() -> [String: Double] {
        guard let data = try? Data(contentsOf: Paths.projects),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return decoded
    }
}
