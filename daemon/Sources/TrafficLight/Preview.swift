import SwiftUI

/// `traffic-light preview` — every Signal, every wording, every chime, in one
/// window.
///
/// Native rather than a web page on purpose. The colours are `NSColor` system
/// colours that macOS adjusts for light mode, dark mode and Increase Contrast;
/// the bulbs are the real ink-centred SF Symbols; the chimes play through the
/// real `NSSound`. A mock-up in HTML would approximate all three and let a
/// choice look right here and wrong in the menu bar.
///
/// Sound changes save to `config.json` immediately, and the running daemon
/// picks them up within a second — so you can audition against the real thing.
struct PreviewPanel: View {
    @State private var sounds: [String: String]
    @State private var bellEnabled: Bool
    @State private var lastPlayed: String?
    @State private var volume: Double

    init() {
        let config = Config.load()
        _sounds = State(initialValue: config.bell.sounds)
        _bellEnabled = State(initialValue: config.bell.enabled)
        _volume = State(initialValue: config.bell.volume)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                signals
                Divider()
                chimes
                Divider()
                elsewhere
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 720, minHeight: 620)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Traffic Light").font(.system(size: 22, weight: .semibold))
            Text("Everything the menu bar and the floating bar can show you.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Signals

    private var signals: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Signals", "Highest wins when sessions disagree — Broken first, Idle last.")

            ForEach(Signal.allCases, id: \.self) { signal in
                HStack(alignment: .top, spacing: 14) {
                    bulb(signal)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(signal.rawValue).font(.system(size: 14, weight: .semibold))
                            Text(PreviewCopy.meaning[signal] ?? "")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        FlowRow(items: PreviewCopy.examples[signal] ?? [])
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// The real `BulbView`, not a still image — otherwise Working's rotation,
    /// the one thing you cannot judge from a screenshot, is the one thing this
    /// panel fails to show.
    private func bulb(_ signal: Signal, size: CGFloat = 18) -> some View {
        LiveBulb(signal: signal, pointSize: size)
            .frame(width: size + 4, height: size + 4)
    }

    // MARK: Chimes

    private var chimes: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Chimes",
                         "Rings on a change into a Signal, never while it sits there. "
                         + "Most urgent wins; at most one every 2 seconds.")

            Toggle("Bell enabled", isOn: $bellEnabled)
                .onChange(of: bellEnabled) { _, _ in save() }
                .toggleStyle(.switch)

            ForEach(Signal.allCases, id: \.self) { signal in
                HStack(spacing: 12) {
                    bulb(signal).frame(width: 22)
                    Text(signal.rawValue).frame(width: 74, alignment: .leading)

                    Picker("", selection: binding(for: signal)) {
                        Text("silent").tag("")
                        Divider()
                        ForEach(Config.systemSounds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)

                    Button {
                        play(sounds[signal.rawValue])
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(sounds[signal.rawValue]?.isEmpty != false)

                    Text(sounds[signal.rawValue]?.isEmpty != false
                         ? "no sound — silence is the default for Working and Idle"
                         : "")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Audition every sound").font(.system(size: 12, weight: .medium))
                FlowButtons(items: Config.systemSounds, playing: lastPlayed) { play($0) }
            }
            .padding(.top, 4)

            Text("Changes save to config.json straight away. The daemon picks them up "
                 + "within a second — no restart.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Everything else

    private var elsewhere: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Elsewhere", "Wordings that are not a Signal.")
            ForEach(PreviewCopy.chrome, id: \.0) { item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.0)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 300, alignment: .leading)
                        .textSelection(.enabled)
                    Text(item.1).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Plumbing

    private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func binding(for signal: Signal) -> Binding<String> {
        Binding(
            get: { sounds[signal.rawValue] ?? "" },
            set: { value in
                if value.isEmpty { sounds.removeValue(forKey: signal.rawValue) }
                else { sounds[signal.rawValue] = value; play(value) }
                save()
            })
    }

    /// Through `Bell.play`, like every other audition. Calling `NSSound`
    /// directly meant the preview ignored `bell.volume` — so a chime set to
    /// 20% played here at full, which is precisely what `Bell.play`'s comment
    /// says must not happen: "a sound that plays in Settings is a sound that
    /// will play in anger".
    private func play(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        lastPlayed = name
        Bell.play(name, volume: volume)
    }

    /// Read-modify-write rather than encoding the whole struct from memory:
    /// the panel only owns the bell, and clobbering someone's push settings
    /// because they happened to open this window would be unforgivable.
    private func save() {
        var config = Config.load()
        config.bell.sounds = sounds
        config.bell.enabled = bellEnabled
        config.write()
    }
}

/// The copy shown in the panel, kept beside the panel rather than derived from
/// the state machine — these are illustrative examples with realistic values,
/// not live output.
enum PreviewCopy {
    static let meaning: [Signal: String] = [
        .broken: "crashed, stalled, or asked for help — go rescue it",
        .asking: "frozen, waiting on a human decision",
        .done: "the turn ended and there is something to read",
        .working: "making progress on its own — leave it alone",
        .idle: "nothing claiming your attention — just opened, gone quiet, or not reporting"
    ]

    static let examples: [Signal: [String]] = [
        .broken: [Wording.crashed, Wording.stuck(for: 1834),
                  "cannot reach the staging database", Wording.askedForHelp],
        .asking: [Wording.needsPermission("Bash", waiting: 74),
                  Wording.waitingForAnswer, Wording.waitingForYou],
        .done: [Wording.yourTurn],
        .working: [Wording.thinking, Wording.running("Bash"), Wording.running("Read"),
                   Wording.running("Edit"), Wording.running("Task"),
                   Wording.backgroundTasks(2), Wording.compacting],
        .idle: [Wording.started("startup"), Wording.started("resume"),
                Wording.started("compact"), Wording.closed, Wording.notConnected]
    ]

    static let chrome: [(String, String)] = [
        ("Traffic Light — Working", "tooltip on the menu bar dot"),
        (Wording.nothingConnected, "menu, when no session has hooks"),
        (Wording.othersNotConnected(1), "menu, below the rule"),
        (Wording.othersNotConnected(3), "the plural form"),
        ("Install the plugin there, then reopen the session.",
         "tooltip on that line, after the paths"),
        ("Quit Traffic Light", "menu, ⌘Q"),
        ("traffic · traffic-light", "terminal `status`: title, then project"),
        ("SessionEnd:other", "set on a clean exit — the row usually vanishes first")
    ]
}

/// Wrapping row of example chips.
struct FlowRow: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    .textSelection(.enabled)
            }
        }
    }
}

struct FlowButtons: View {
    let items: [String]
    let playing: String?
    let action: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { action(item) } label: {
                    Text(item).font(.system(size: 11))
                        .frame(minWidth: 62)
                }
                .buttonStyle(.bordered)
                .tint(playing == item ? .accentColor : nil)
            }
        }
    }
}

/// Minimal wrapping layout — the panel needs one and pulling in a dependency
/// for twenty lines would be worse.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

enum Preview {
    static func run() {
        let app = NSApplication.shared
        // .regular, unlike the daemon: this window is meant to be focused and
        // typed into, so it gets a Dock icon for as long as it is open.
        app.setActivationPolicy(.regular)
        // With no .app bundle there is no icon file for the Dock to find, so
        // it would show the generic executable placeholder. Setting it at
        // runtime is the whole reason the mark is drawn rather than shipped.
        app.applicationIconImage = AppIcon.image(size: 512)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Traffic Light — reference"
        window.contentView = NSHostingView(rootView: PreviewPanel())
        window.center()
        window.makeKeyAndOrderFront(nil)

        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

/// Closing the window ends the process — this is a one-shot inspector, not
/// something that should linger in the Dock after its window is gone.
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Bridges the AppKit `BulbView` into SwiftUI so the panel shows exactly what
/// the menu bar and the floating bar show, animation included.
struct LiveBulb: NSViewRepresentable {
    let signal: Signal
    let pointSize: CGFloat

    func makeNSView(context: Context) -> BulbView {
        let view = BulbView(pointSize: pointSize)
        view.show(signal)
        return view
    }

    func updateNSView(_ view: BulbView, context: Context) { view.show(signal) }

    /// Without this SwiftUI proposes a size the view never reconciles with its
    /// layer geometry, and the drawn ring comes out a fraction of the size of
    /// the symbols beside it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BulbView,
                      context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}
