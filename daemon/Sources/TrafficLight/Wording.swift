import Foundation

/// Everything a human reads.
///
/// Kept in one place because the notes started life as Claude Code's own hook
/// event names — `UserPromptSubmit`, `Stop`, `SessionStart:startup` — which is
/// API vocabulary. Nobody glancing at a menu bar should have to know the hook
/// API to read their own status light. The note answers *what is happening and
/// why do you care*, never *which event fired*.
///
/// The raw event name is not thrown away: it is carried alongside and shown in
/// the menu row's tooltip, because the moment the light is wrong is the moment
/// you most want to know exactly what fired.
enum Wording {
    /// Durations as a person would say them. Under a minute stays in seconds,
    /// which is the range where a second is something you actually feel;
    /// past that, `1834s` is arithmetic, not information.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60) min" }
        if total < 86_400 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        // Past a day, hours stop being a unit anyone converts in their head:
        // "104h" is arithmetic homework where "4 days" is the answer. Only
        // dormancy ever gets this far — every other duration here is a stall
        // or a wait, and both are resolved long before.
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let unit = days == 1 ? "day" : "days"
        return hours == 0 ? "\(days) \(unit)" : "\(days) \(unit) \(hours)h"
    }

    /// A living session that has said nothing for a long time.
    ///
    /// Says how long rather than just "dormant": the number is the whole
    /// point. Four days tells you this is abandoned and worth closing; nine
    /// hours tells you it is yesterday's, and still yours.
    static func dormant(for seconds: Double) -> String {
        "Quiet for \(duration(seconds))"
    }

    /// What a tool is *doing*, rather than what it is called. `Bash` is precise
    /// and means nothing to anyone who has not read Claude Code's tool list.
    static func activity(for tool: String) -> String {
        switch tool {
        case "Bash", "BashOutput", "KillShell": "Running a command"
        case "Read", "NotebookRead": "Reading a file"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "Editing"
        case "Grep", "Glob", "LS": "Searching"
        case "Task", "Agent": "Running a subagent"
        case "WebFetch", "WebSearch": "Searching the web"
        case "TodoWrite", "TaskCreate", "TaskUpdate": "Updating its plan"
        default:
            // MCP tools arrive as `mcp__server__tool`, which is unreadable and
            // unmappable — there is an unbounded number of them. Take the last
            // segment and say what is being used.
            //
            // Split on the double underscore, not on `_`: the tool's own name
            // may contain single underscores, and splitting on those turned
            // `mcp__server__javascript_tool` into "Using tool".
            tool.hasPrefix("mcp__")
                ? "Using \(tool.components(separatedBy: "__").last.flatMap { $0.isEmpty ? nil : $0 } ?? tool)"
                : tool
        }
    }

    // MARK: Working

    static let thinking = "Working…"
    static func running(_ tool: String) -> String { "\(activity(for: tool))…" }
    static func backgroundTasks(_ count: Int) -> String {
        "\(count) background task\(count == 1 ? "" : "s")"
    }
    static let compacting = "Compacting…"

    // MARK: Asking

    /// Named for your problem, not for our inference. Nothing fires when a
    /// permission prompt opens, so this state is deduced from a tool call that
    /// never closed — but "unanswered" describes how we worked it out, which
    /// is not what you need to know.
    static func needsPermission(_ tool: String, waiting: Double) -> String {
        "Needs permission · \(activity(for: tool)) · \(duration(waiting))"
    }
    static let waitingForAnswer = "Waiting for your answer"
    static let waitingForYou = "Waiting for you"

    /// Did the turn end on a question?
    ///
    /// Only the last non-empty line is read. A question asked halfway through
    /// a long answer has usually been answered by the rest of it, and matching
    /// anywhere in the message turns every explanatory "why?" into an amber
    /// light. The trailing line is where a turn puts what it wants back.
    ///
    /// Matching the whole line rather than its final character is deliberate:
    /// real questions carry their options after the mark — "Post this? (yes /
    /// edit / cancel)" — and a bare `hasSuffix("?")` misses every one of them.
    static func endsWithQuestion(_ text: String?) -> Bool {
        guard let text else { return false }
        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // A turn very often ends with the command that answers the question it
        // just asked, and the closing fence is then the last line — which said
        // Done for a Session that had stopped on the reader. Drop trailing
        // fenced blocks and judge the prose that introduced them.
        while let last = lines.last {
            if last.isEmpty { lines.removeLast(); continue }
            guard last.hasPrefix("```") else { break }
            lines.removeLast()
            while let inner = lines.last, !inner.hasPrefix("```") { lines.removeLast() }
            if !lines.isEmpty { lines.removeLast() }
        }

        guard let line = lines.last(where: { !$0.isEmpty }) else { return false }
        if line.hasSuffix("?") { return true }

        // The mark is not always last: "Create this issue? (yes / edit / cancel)"
        // puts the options after it. Accepting only a short bracketed tail is
        // what separates that from a line of code — `?? "?"`, a ternary, a URL
        // with a query string — which `contains("?")` scored as a question and
        // lit amber over nothing. A late amber costs a minute; a false one
        // teaches you to ignore the light.
        guard let mark = line.lastIndex(of: "?") else { return false }
        let tail = line[line.index(after: mark)...].trimmingCharacters(in: .whitespaces)
        guard tail.count <= 40, let open = tail.first, let close = tail.last else { return false }
        return (open == "(" && close == ")") || (open == "[" && close == "]")
    }

    // MARK: Done

    /// The turn ended, nothing is owed to the machine, and nothing was asked
    /// of you — the work is simply ready to read.
    static let yourTurn = "Your turn"

    // MARK: Broken

    static let crashed = "Crashed"
    static func stuck(for seconds: Double) -> String { "Stuck for \(duration(seconds))" }
    static let askedForHelp = "Asked for help"

    // MARK: Idle

    static func started(_ source: String?) -> String {
        switch source {
        case "startup": "Just opened"
        case "resume": "Reconnected"
        case "compact": "Resumed"
        case "clear": "Cleared"
        default: "Ready"
        }
    }
    static let closed = "Closed"
    static let notConnected = "Not connected"

    // MARK: Menu chrome

    static let nothingConnected = "No sessions connected"
    static func othersNotConnected(_ count: Int) -> String {
        "\(count) session\(count == 1 ? "" : "s") not connected"
    }
}
