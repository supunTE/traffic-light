import AppKit

/// Rings on Transitions, never on Signals. A Session that sits in `Asking`
/// rings once and then stays quiet, which is the whole difference between an
/// ambient tool and an alarm you learn to ignore.
final class BellRenderer: Renderer {
    private let store: ConfigStore
    private var lastRing: Double = 0

    init(store: ConfigStore) { self.store = store }

    func render(rows: [Row], aggregate: Signal, transitions: [Transition],
                attention: AttentionState) {
        // Read every time, not once at startup: the preview panel changes
        // these while the daemon is running, and a sound you cannot audition
        // against the real thing is a sound you cannot choose.
        let config = store.current
        guard config.bell.enabled, !transitions.isEmpty else { return }

        // Only Transitions *into* a Signal that has a sound. Falling back to
        // Working or Idle is progress, and progress is silent.
        //
        // Judged per Session, not globally: a project set to Quiet must not
        // silence the chime for a different one that is Broken. Both Quiet and
        // Off duty mute the bell — the difference between them is the phone.
        let ringable = transitions.compactMap { t -> (Transition, String)? in
            guard attention.level(forProject: t.project).chimesAllowed else { return nil }
            guard let sound = config.bell.sounds[t.to.rawValue] else { return nil }
            return (t, sound)
        }
        guard let (_, sound) = ringable.min(by: { $0.0.to.rank < $1.0.to.rank }) else { return }

        // Five sessions finishing at once is one event to a human.
        let now = Date().timeIntervalSince1970
        guard now - lastRing >= config.bell.minIntervalSeconds else { return }
        lastRing = now

        Bell.play(sound, volume: config.bell.volume)
    }
}
