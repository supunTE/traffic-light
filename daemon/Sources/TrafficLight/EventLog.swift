import Foundation

/// Every hook payload, kept, one JSON object per line.
///
/// The daemon already sees everything and throws it away: `state.json` is a
/// snapshot rewritten every second, and the inbox file is deleted the moment
/// it is applied. So every question that needs *what happened over time* is
/// unanswerable, and stays that way however long anyone waits — the ~900 s API
/// hang that fires no hook, a wake-up nobody asked for, how long a permission
/// prompt sat there, a payload whose shape drifted.
///
/// It lives in the daemon rather than in hooks deliberately. Logging from a
/// hook makes every real session pay for the instrumentation, because the
/// session waits for the hook. Out here an append costs a session nothing, for
/// the simple reason that nothing is waiting on it.
///
/// **This is the least important thing the daemon does.** Every failure is
/// swallowed: a log that cannot be written must never stop the light working.
final class EventLog {
    /// Read every write, so switching the log off — or turning the text on
    /// while debugging — takes effect without restarting the daemon, the same
    /// way the bell and the push do.
    private let config: ConfigStore
    private var handle: FileHandle?
    private var written: Int = 0

    init(config: ConfigStore) {
        self.config = config
    }

    /// The free-text fields. Every question this log exists for is about
    /// *when* something happened or *what shape* it had, and none of them read
    /// the words — but the words are almost all of the bytes and all of the
    /// sensitivity. Their sizes are kept, because size is shape: an enormous
    /// `tool_response` is visible as a stall candidate without storing a line
    /// of it.
    private static let textFields = ["tool_input", "tool_response", "prompt",
                                     "last_assistant_message"]

    /// The raw payload, compacted to a single line, with the arrival time the
    /// daemon observed. `written` is the file's mtime in nanoseconds, which is
    /// the true order — the payload's own `at` is whole seconds and cannot
    /// separate two events inside one.
    func append(_ data: Data, written when: Double) {
        guard config.current.log.enabled else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            unreadable(data)
            return
        }
        var record = object
        record["_at"] = when
        if !config.current.log.includeText, var payload = record["payload"] as? [String: Any] {
            var dropped: [String: Int] = [:]
            for field in EventLog.textFields {
                guard let value = payload[field] else { continue }
                let text = (value as? String) ?? (try? JSONSerialization.data(withJSONObject: value))
                    .map { String(decoding: $0, as: UTF8.self) } ?? ""
                dropped[field] = text.count
                payload.removeValue(forKey: field)
            }
            if !dropped.isEmpty { payload["_dropped"] = dropped }
            record["payload"] = payload
        }
        write(record)
    }

    /// A payload that did not decode. Kept as text rather than discarded,
    /// because this is the shape of Claude Code changing something.
    func unreadable(_ data: Data) {
        guard config.current.log.enabled else { return }
        write([
            "_at": Date().timeIntervalSince1970,
            "_unreadable": true,
            "_bytes": data.count,
            // The only place raw text lands with includeText off: a payload
            // that did not decode cannot be stripped field by field, and its
            // literal bytes are the whole reason for recording it. Truncated.
            "_raw": String(data: data.prefix(2048), encoding: .utf8) ?? "<not utf-8>"
        ])
    }

    private func write(_ record: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: record,
                                                     options: [.withoutEscapingSlashes])
        else { return }
        line.append(0x0A)

        rotateIfNeeded(adding: line.count)
        guard let handle = openIfNeeded() else { return }
        try? handle.write(contentsOf: line)
        written += line.count
    }

    /// Let go of the file so somebody else can delete it.
    ///
    /// The handle is opened once and kept, so a log removed from underneath
    /// this process would go on being written into as an unlinked inode —
    /// logging that looks switched on and produces nothing. `openIfNeeded`
    /// reopens lazily on the next event, and recounts the size from the file
    /// it finds, so releasing costs one open and nothing else.
    func release() {
        try? handle?.close()
        handle = nil
        written = 0
    }

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Paths.events.path) {
            // 0600 from the moment it exists, never after: `UserPromptSubmit`
            // carries the whole prompt and `Stop` the whole reply, so this file
            // holds more of the day's thinking than anything else on disk.
            fm.createFile(atPath: Paths.events.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        // O_APPEND, so every write lands at the true end of the file rather
        // than at an offset this process cached once and never revalidated.
        // Without it a second writer overwrites the first's lines, and a file
        // deleted from under the daemon is written into forever as an unlinked
        // inode — logging that looks on and produces nothing.
        let fd = open(Paths.events.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return nil }
        let opened = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // The size the file already has, so rotation counts the whole file and
        // not just this run's writes — otherwise a daemon restarted often
        // enough never reaches `maxBytes` and the log grows without a ceiling.
        written = (try? fm.attributesOfItem(atPath: Paths.events.path))
            .flatMap { $0[.size] as? Int } ?? 0
        handle = opened
        return opened
    }

    private func rotateIfNeeded(adding bytes: Int) {
        guard written + bytes > config.current.log.maxBytes, written > 0 else { return }
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: Paths.eventsPrevious)
        try? fm.moveItem(at: Paths.events, to: Paths.eventsPrevious)
        written = 0
    }
}
