import Foundation

/// ntfy: notify-only, no pairing, no account, works from every worktree at
/// once. The daemon posts — never a hook — so a dead network can only ever
/// delay a notification, not hang a Claude Code session.
final class PushRenderer: Renderer {
    private let store: ConfigStore
    private var lastPush: Double = 0

    /// Transitions that have not been delivered yet, newest per Session.
    ///
    /// This used to be a `min(by: rank)` and nothing else: three Sessions
    /// stopping in the same second produced one notification and two silent
    /// losses, and a Transition arriving inside the rate-limit window was
    /// discarded outright. Neither ever reached the network — they were chosen
    /// against, in memory, and the daemon reports each Transition exactly once,
    /// so there was nothing left to resend.
    ///
    /// That shape is inherited from `BellRenderer`, where it is right: five
    /// Sessions finishing at once is one event to a human, and a chime carries
    /// no content to lose. A notification is the opposite — when you are away
    /// from the Mac it is the only channel there is, and it carries the whole
    /// message. So nothing is dropped for being less urgent; it waits and
    /// travels with the next send.
    ///
    /// Keyed by Session, so a Session replaces its own earlier entry rather
    /// than queueing behind it. The buffer cannot outgrow the session list.
    private var pending: [String: Transition] = [:]

    init(store: ConfigStore) { self.store = store }

    func render(rows: [Row], aggregate: Signal, transitions: [Transition],
                attention: AttentionState) {
        let config = store.current
        guard config.push.enabled, !config.push.topic.isEmpty else { return }
        let wanted = Set(config.push.signals)
        // Off duty sends nothing; Quiet still sends, silently. Filtered per
        // Session so one muted project cannot take the others with it.
        for t in transitions where wanted.contains(t.to.rawValue)
            && attention.level(forProject: t.project).pushAllowed {
            pending[t.sessionId] = t
        }
        guard !pending.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        // Still inside the quiet window: hold everything and try again next
        // tick. The interval now limits how often you are interrupted, not how
        // much you are told — which is what it was always for.
        guard now - lastPush >= config.push.minIntervalSeconds else { return }

        // Waiting costs nothing until what was waiting stops being true.
        //
        // A Session can finish, be answered at the desk, and be working again
        // inside the window — and "Your turn" delivered after that is a claim
        // the phone has no way to correct. So every held Transition is checked
        // against the Session's signal right now, and anything that has moved
        // on, gone, or slipped off duty in the meantime is dropped rather than
        // delivered late. Without this step, holding would be worse than
        // discarding.
        let live = Dictionary(rows.map { ($0.sessionId, $0.signal) },
                              uniquingKeysWith: { first, _ in first })
        let batch = pending.values
            .filter { live[$0.sessionId] == $0.to }
            .filter { attention.level(forProject: $0.project).pushAllowed }
            .sorted { ($0.to.rank, $0.name) < ($1.to.rank, $1.name) }
        // Cleared whether or not anything survived: a stale entry has had its
        // chance, and keeping it would mean re-testing it forever.
        pending.removeAll()
        guard !batch.isEmpty else { return }

        lastPush = now
        post(batch, attention: attention)
    }

    /// One notification, however many Sessions it speaks for.
    private func post(_ batch: [Transition], attention: AttentionState) {
        let config = store.current
        guard let url = URL(string: "\(config.push.server)/\(config.push.topic)") else { return }
        // Sorted by rank, so the first is the most urgent. It sets the icon and
        // the priority for the whole message: a Broken travelling alongside a
        // Done must not be softened by the company it keeps.
        guard let most = batch.first else { return }

        // The topic name is the only thing standing between this message and
        // anyone who guesses it, so the body says which session and what
        // happened — never what was said, unless explicitly opted in.
        // `name` already carries the label the user chose: it is applied once,
        // in `Store.rows`. This used to re-derive it here and only when
        // `hideSessionTitle` was set, which is how a name typed into Settings
        // could reach the phone and nothing else.
        var body: String
        if batch.count == 1 {
            body = most.note
            // Only ever for a single Session. Four hundred characters of one
            // reply is a notification; four hundred each from five of them is
            // a wall, and the point of a batch is the summary.
            if config.push.includeText, let text = most.text {
                body += "\n\n" + String(text.prefix(400))
            }
        } else {
            body = batch.map { "\($0.name) — \($0.note)" }.joined(separator: "\n")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        // The title identifies, and the tag says what kind of thing it is.
        //
        // It used to be the Signal — every notification titled `Done` or
        // `Asking`, with the one word that says *which* session buried in
        // smaller text below. Several of them in a notification shade were
        // indistinguishable at the glance the whole feature is designed
        // around. The state has not been lost: it is in the emoji, and in how
        // insistently the phone announces it.
        request.setValue(batch.count == 1 ? most.name : "\(batch.count) sessions",
                         forHTTPHeaderField: "Title")
        // One step below where this started, across the board. Urgent on ntfy
        // bypasses the phone's own quiet hours, which is more than a blocked
        // session has earned — and once every Signal that pushes sits a step
        // down, the *gaps* still carry the ranking. What matters is that
        // Broken outranks Asking outranks Done, not that any of them shout.
        //
        // Asking keeps a level that still survives doze, because a Session in
        // that state is frozen until it is answered. Done sits at low: it is
        // the one that can wait, and it is the most frequent.
        var priority = (config.push.priorities[most.to.rawValue]
            .flatMap(PushPriority.init(rawValue:)) ?? PushPriority.default(for: most.to)).rawValue
        // Quiet is not "do not send", it is "do not buzz". ntfy's min priority
        // reaches the phone without sound or vibration and still lands in the
        // notification list, so an hour of silence costs nothing you cannot
        // catch up on when you pick the phone up.
        //
        // Every Session in the batch has to be quiet for the batch to be. One
        // project observing quiet hours cannot silence a different one that is
        // not, which is the same rule the per-Session filter above applies.
        if batch.allSatisfy({ attention.level(forProject: $0.project).forcesLowestPriority }) {
            priority = "min"
        }
        request.setValue(priority, forHTTPHeaderField: "Priority")
        request.setValue(most.to.pushTag, forHTTPHeaderField: "Tags")
        request.timeoutInterval = 10

        // Not fire-and-forget. Discarding the error *and* the status made a
        // 403 from an authenticated server, a topic the phone has unsubscribed
        // from, and a captive portal all look exactly like a healthy push
        // nobody has picked their phone up for — on the one feature whose
        // whole premise is that you can walk away and trust it.
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                if let error {
                    PushHealth.shared.failed(error.localizedDescription)
                } else if !(200...299).contains(code) {
                    PushHealth.shared.failed("server said \(code)")
                } else {
                    PushHealth.shared.succeeded()
                }
            }
        }.resume()
    }
}

/// The last thing the push transport actually did.
///
/// Kept because a failed push is otherwise indistinguishable from a quiet
/// afternoon: the request was fired and its result discarded, so a wrong
/// server, a revoked topic or no network all looked exactly like success.
/// Health reads this, so the window can say so.
@MainActor
final class PushHealth {
    static let shared = PushHealth()

    private(set) var lastError: String?
    private(set) var lastSuccess: Date?

    func failed(_ reason: String) { lastError = reason }
    func succeeded() { lastError = nil; lastSuccess = Date() }
}
