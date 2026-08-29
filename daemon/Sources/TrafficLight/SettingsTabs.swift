import AppKit
import SwiftUI

// MARK: - Notifications

/// One row per Signal: whether it reaches the phone, and how insistently.
///
/// The chime used to be a fourth column here, on the theory that everything
/// about a Signal belongs in one row. It was the wrong row. A chime is
/// `NSSound` on this Mac, nothing is sent to the phone that could choose its
/// sound — `Priority` is the only phone-side lever there is — so under a card
/// headed *Send to phone* the column described itself wrongly, and stayed live
/// with push switched off, which is exactly what a misplaced control looks
/// like. It lives on the Chimes page, with the volume and the audition button.
///
/// `Working` and `Idle` are shown greyed rather than hidden, so "these never
/// notify" is a visible rule rather than a gap you wonder about.
struct NotificationsPage: View {
    @ObservedObject var model: SettingsModel
    let live: LiveState
    @State private var revealTopic = false
    @State private var confirmRotate = false
    @State private var subscribing = false
    @State private var testResult: String?

    var body: some View {
        SettingsPageBody(page: .notifications) {
            // The master switch is its own card. Sharing one with the table
            // made a single divider carry the whole difference between "does
            // this feature run at all" and "how does each Signal behave" —
            // which is not a distinction a hairline can hold.
            Card {
                SettingRow(label: "Send to phone") {
                    Toggle("", isOn: Binding(
                        get: { model.config.push.enabled },
                        set: { model.config.push.enabled = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Send to phone")
                }
            }
            Card(title: "Customise each signal") { signalTable }

            // Side by side rather than two full-width bands. Neither has
            // enough in it to earn the whole width, and stacked they pushed
            // everything below the fold for no reason. Health takes a fixed
            // narrow column because its content is three short lines and a
            // button; the topic gets the rest, since it holds a 34-character
            // string you have to be able to read.
            HStack(alignment: .top, spacing: Metrics.sectionGap) {
                Card(title: "Listen through ntfy",
                     blurb: "Get a notification on your phone whenever a signal "
                            + "changes, through the free ntfy app.",
                     equalHeight: true) { topic }
                Card(title: "How things are running",
                     blurb: "Whether the pieces are talking to each other.",
                     equalHeight: true) { health }
                    .frame(width: 260)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $subscribing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Subscribe on your phone")
                    .font(.system(size: 15, weight: .semibold))
                subscribePanel
                HStack {
                    Spacer()
                    Button("Done") { subscribing = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            // Wide enough for the revealed topic. 34 monospaced characters
            // at 12pt is ~245pt, which beside the QR and the two icon buttons
            // did not fit in 470 — the topic truncated in the middle, which is
            // the one thing a value you are copying onto a phone must never do.
            .frame(width: 520)
        }
        .confirmationDialog("Generate a new topic?", isPresented: $confirmRotate) {
            Button("Generate new topic", role: .destructive) {
                model.config.push.topic = Config.freshTopic()
                revealTopic = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your phone will stop receiving until you subscribe to the new "
                 + "topic. Remember, the topic name is the only thing keeping these "
                 + "notifications private.")
        }
    }

    /// Column widths live here rather than at each use, because a header that
    /// is two points off its column is the sort of thing you see without
    /// being able to say why.
    ///
    /// The first column was headed "Phone", which named the destination rather
    /// than the question. Every row in the table is about the phone — that is
    /// what the card is — so the header said nothing, and next to "Priority",
    /// which does name a decision, it read as a mislabel. "Send" is the
    /// decision the checkbox makes.
    private static let phoneColumn: CGFloat = 52
    private static let priorityColumn: CGFloat = 112
    /// See `signalRow`. The checkbox's drawn glyph is 4.75pt right of its
    /// frame's centre, so it needs pulling back by that much to sit under the
    /// header.
    private static let checkboxOpticalOffset: CGFloat = -4.75

    private var signalTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Text("Send")
                    .frame(width: NotificationsPage.phoneColumn, alignment: .center)
                Text("Priority")
                    .frame(width: NotificationsPage.priorityColumn, alignment: .center)
            }
            .font(.system(size: Metrics.noteSize))
            .foregroundStyle(.secondary)
            .padding(.top, Metrics.blockPadding)
            .allowsHitTesting(false)

            ForEach([Signal.broken, .asking, .done], id: \.self) { signal in
                signalRow(signal)
                Divider()
            }

            // The explanation stays beside the label rather than pushed to the
            // trailing edge: out there it lines up under the Priority column
            // and reads as a value for this row, which is the one thing it is
            // not — these two signals have no controls at all.
            HStack(spacing: 8) {
                SignalDot(signal: .working, muted: true)
                Text("Working, Idle").font(.system(size: Metrics.labelSize))
                Text("never, because progress isn't news")
                    .font(.system(size: Metrics.labelSize))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 9)
            .frame(minHeight: Metrics.rowHeight)
            .allowsHitTesting(false)
        }
    }

    private func signalRow(_ signal: Signal) -> some View {
        // 8, not 12: the bulb carries two points of its own padding, so the
        // gap you set is not the gap you see.
        HStack(spacing: 8) {
            SignalDot(signal: signal)
            Text(signal.rawValue).font(.system(size: Metrics.labelSize))

            Spacer(minLength: 12)

            // `labelsHidden` hides the label from the screen *and* from
            // VoiceOver, so every one of these announced itself as an unnamed
            // checkbox — and in a table of three identical rows that is not a
            // control anybody can use. The row's own text is the label; it just
            // has to be said again here, because a row is not a grouping
            // VoiceOver reads on the caller's behalf.
            Toggle("", isOn: pushes(signal))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Send \(signal.rawValue) to phone")
                .frame(width: NotificationsPage.phoneColumn, alignment: .center)
                // A hidden label is not a missing one: AppKit keeps room where
                // the title would go, so the drawn box sits off the centre of
                // the frame SwiftUI centred. Measured at 2x — 9.5px, the
                // same on every row — rather than nudged until it looked
                // right.
                .offset(x: NotificationsPage.checkboxOpticalOffset)

            Picker("", selection: priority(signal)) {
                ForEach(PushPriority.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: NotificationsPage.priorityColumn)
            .accessibilityLabel("\(signal.rawValue) priority")
            .disabled(!model.config.push.signals.contains(signal.rawValue))
        }
        .padding(.vertical, 9)
        .frame(minHeight: Metrics.rowHeight)
    }

    private var topic: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // 12pt monospaced sits at the same apparent size as 13pt
                // system text — the two scales do not share a number.
                Text(revealTopic ? model.config.push.topic
                     : String(repeating: "•", count: 22))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Palette.field, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Palette.hairline, lineWidth: 1))
                    // Hidden, the field is 22 bullet characters, and read out
                    // that way it is 22 announcements of nothing. Masked, it
                    // says it is masked; revealed, it says the topic — which is
                    // the state a screen reader can act on either way.
                    .accessibilityLabel("Your ntfy topic")
                    .accessibilityValue(revealTopic ? model.config.push.topic : "Hidden")
                Button(revealTopic ? "Hide" : "Show") { revealTopic.toggle() }
                    .accessibilityLabel(revealTopic ? "Hide the topic" : "Show the topic")
                Button("Copy") { copy(model.config.push.topic) }
                    .accessibilityLabel("Copy the topic")
            }
            // More than the 9 a labelled row uses. These rows are a text
            // field and a pair of buttons rather than a line of text, and
            // controls need more room around them than words do — at 9 the
            // field was almost touching the top of the card.
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Stays as it is. The subtitle above sells the feature; this line
            // states the access model plainly, next to the value it applies
            // to, which is the one place it is worth the words.
            Note("Anyone who knows it can read your notifications, and send their own.")
                .padding(.bottom, 12)

            Divider()

            HStack(spacing: 8) {
                Button("Set up phone") { subscribing = true }
                Spacer(minLength: 8)
                Button("New topic") { confirmRotate = true }
            }
            .padding(.vertical, 12)
        }
    }

    /// The QR carries `ntfy://`, which the Android app registers and which
    /// subscribes on scan. Deep links are documented Android-only, so the same
    /// panel shows the two values as text — an iPhone has to be told them by
    /// hand, and a QR it cannot use would look like a broken feature.
    private var subscribePanel: some View {
        HStack(alignment: .top, spacing: 14) {
            if let qr = QR.image(for: subscribeURL, side: 116) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 116, height: 116)
                    .padding(6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
                // The panel never said what app any of this was for. The QR,
                // the server and the topic are all instructions to something
                // you have to install first, and nothing here named it.
                Text("1. Install **ntfy** on your phone, from the App Store or Google Play.")
                    .font(.system(size: Metrics.labelSize))
                    .fixedSize(horizontal: false, vertical: true)
                Text("2. On Android, scan this code. On iPhone, add a subscription "
                     + "and type in the two values below.")
                    .font(.system(size: Metrics.labelSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
                value("Server", model.config.push.server)
                value("Topic", model.config.push.topic, secret: true)
                Label {
                    Text("Turn on instant delivery, and let ntfy skip battery "
                         + "optimisation. Without both, an Asking notification can arrive "
                         + "up to fifteen minutes late, and that is the one that means a "
                         + "session is waiting on you.")
                        .font(.system(size: Metrics.noteSize))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: Metrics.noteSize))
                }
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// `secret` masks the value and offers the eye beside it. The real string
    /// is always what arrives here — masking is display only, so Copy copies
    /// the topic whether or not it is on screen. Reading it off the screen to
    /// type into a phone is exactly what this sheet is for, so hiding it with
    /// no way to look would make the panel useless; and it shares the card's
    /// `revealTopic`, so the two never disagree about what is showing.
    private func value(_ name: String, _ text: String, secret: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: Metrics.noteSize))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(secret && !revealTopic ? String(repeating: "•", count: 18) : text)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            if secret {
                Button { revealTopic.toggle() } label: {
                    Image(systemName: revealTopic ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(revealTopic ? "Hide the topic" : "Show the topic")
                .accessibilityLabel(revealTopic ? "Hide the topic" : "Show the topic")
            }
            Button { copy(text) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Copy")
            // There are three of these in the sheet, one per row. "Copy" on
            // its own is the same word three times for three different values.
            .accessibilityLabel("Copy the \(name.lowercased())")
        }
    }

    private var health: some View {
        let age = live.stateAge
        let reporting = live.reporting
        // Stacked, not two columns. In a 260pt card the three lines and the
        // button cannot sit beside each other without the detail text running
        // into the button.
        return VStack(alignment: .leading, spacing: 10) {
            HealthLine(ok: age < 5, name: "Daemon",
                       detail: age < 5 ? "state \(age)s old" : "state is stale")
            HealthLine(ok: reporting > 0, name: "Hooks",
                       detail: "\(reporting) session\(reporting == 1 ? "" : "s") reporting")
            HealthLine(ok: pushOK, name: "Push", detail: pushDetail)
            HStack(spacing: 8) {
                Button("Send a test push") { sendTest() }
                    .disabled(!model.config.push.enabled || model.config.push.topic.isEmpty)
                Spacer(minLength: 0)
            }
            // The button is an action, the three lines above it are a readout.
            // At 10pt apart they read as a fourth line of the same list.
            .padding(.top, 8)
            if let testResult {
                Text(testResult)
                    .font(.system(size: Metrics.noteSize))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    /// Green only when push is on, addressable, and the last attempt worked.
    private var pushOK: Bool {
        model.config.push.enabled && !model.config.push.topic.isEmpty
            && PushHealth.shared.lastError == nil
    }

    private var pushDetail: String {
        guard model.config.push.enabled else { return "off" }
        if let error = PushHealth.shared.lastError { return error }
        return model.config.push.server
    }

    // MARK: plumbing

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func sendTest() {
        testResult = "sending…"
        Push.test(config: model.config) { ok in
            testResult = ok ? "Sent, check your phone" : "Could not reach the server"
        }
    }

    /// `?display=` labels the subscription in the app rather than showing 34
    /// random characters; `?secure=false` is what a self-hosted LAN server over
    /// plain http needs, and is derived rather than asked for.
    private var subscribeURL: String {
        let server = model.config.push.server
        let host = server
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        var url = "ntfy://\(host)/\(model.config.push.topic)?display=Traffic%20Light"
        if server.hasPrefix("http://") { url += "&secure=false" }
        return url
    }

    private func pushes(_ signal: Signal) -> Binding<Bool> {
        Binding(
            get: { model.config.push.signals.contains(signal.rawValue) },
            set: { on in
                var list = Set(model.config.push.signals)
                if on { list.insert(signal.rawValue) } else { list.remove(signal.rawValue) }
                model.config.push.signals = Signal.allCases
                    .filter { list.contains($0.rawValue) }.map(\.rawValue)
            })
    }

    private func priority(_ signal: Signal) -> Binding<PushPriority> {
        Binding(
            get: {
                PushPriority(rawValue: model.config.push.priorities[signal.rawValue] ?? "")
                    ?? PushPriority.default(for: signal)
            },
            set: { model.config.push.priorities[signal.rawValue] = $0.rawValue })
    }
}

// MARK: - Chimes

struct ChimesPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPageBody(page: .chimes) {
            // Does not restate the page blurb above it, which already says
            // chimes ring on a change rather than on a state. Two sentences
            // apart saying the same thing is how a window starts to look like
            // it was assembled rather than written.
            Card(blurb: "A session waiting on you rings once, not over and over. "
                        + "If several finish together you hear a single chime, for the "
                        + "most urgent one.") {
                SettingRow(label: "Ring a chime on this Mac") {
                    Toggle("", isOn: Binding(
                        get: { model.config.bell.enabled },
                        set: { model.config.bell.enabled = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Ring a chime on this Mac")
                }
                Divider()
                SettingRow(label: "Volume") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { model.config.bell.volume },
                            set: { model.config.bell.volume = $0 }), in: 0...1)
                            .frame(width: 200)
                            .accessibilityLabel("Chime volume")
                            // Announced as a percentage, matching the figure
                            // beside it. A raw 0–1 slider says "0.65" — a
                            // number that appears nowhere on the screen.
                            .accessibilityValue("\(Int(model.config.bell.volume * 100))%")
                        Text("\(Int(model.config.bell.volume * 100))%")
                            .font(.system(size: Metrics.labelSize)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            Card(title: "Pick a sound for each signal") {
                ForEach([Signal.broken, .asking, .done], id: \.self) { signal in
                    SettingRow(label: signal.rawValue) {
                        HStack(spacing: 8) {
                            Picker("", selection: chime(signal)) {
                                Text("Silent").tag("")
                                Divider()
                                ForEach(Config.systemSounds, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden().frame(width: 150)
                            .accessibilityLabel("\(signal.rawValue) chime")
                            Button {
                                if let name = model.config.bell.sounds[signal.rawValue] {
                                    Bell.play(name, volume: model.config.bell.volume)
                                }
                            } label: {
                                Image(systemName: "play.circle").font(.system(size: 14))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Play the \(signal.rawValue) chime")
                            .disabled(model.config.bell.sounds[signal.rawValue] == nil)
                        }
                    }
                    Divider()
                }
                SettingRow(label: "Working, Idle") {
                    Text("always silent")
                        .font(.system(size: Metrics.labelSize))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chime(_ signal: Signal) -> Binding<String> {
        Binding(
            get: { model.config.bell.sounds[signal.rawValue] ?? "" },
            set: { value in
                if value.isEmpty {
                    model.config.bell.sounds.removeValue(forKey: signal.rawValue)
                } else {
                    model.config.bell.sounds[signal.rawValue] = value
                    Bell.play(value, volume: model.config.bell.volume)
                }
            })
    }
}

// MARK: - Quiet hours

struct QuietPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPageBody(page: .quiet) {
            Card(title: "What the two levels do") {
                level(.quiet, "No chimes. Your phone still gets the message, quietly.")
                Divider()
                level(.offDuty, "Nothing is sent, and the floating bar hides itself.")
            }

            Card(title: "Your quiet times") {
                if model.config.attention.windows.isEmpty {
                    empty
                    Divider()
                } else {
                    ForEach($model.config.attention.windows) { $window in
                        let id = window.id
                        WindowRow(window: $window) {
                            model.config.attention.windows.removeAll { $0.id == id }
                        }
                        Divider()
                    }
                }
                HStack {
                    Button {
                        model.config.attention.windows.append(QuietWindow())
                    } label: {
                        Label("Add window", systemImage: "plus")
                            .font(.system(size: Metrics.labelSize, weight: .medium))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Palette.accentSoft,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.vertical, 9)
                .frame(minHeight: Metrics.rowHeight)
            }
        }
    }

    /// Both levels described in one line each. Two lines apiece pushed the
    /// windows — the thing the page is actually for — below the fold.
    private func level(_ level: Attention, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(level.rawValue)
                .font(.system(size: Metrics.labelSize, weight: .medium))
                .frame(width: 68, alignment: .leading)
            Text(text)
                .font(.system(size: Metrics.labelSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .frame(minHeight: Metrics.rowHeight)
        .allowsHitTesting(false)
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 15)).foregroundStyle(.secondary)
                // Decoration beside a sentence that already says this.
                .accessibilityHidden(true)
            Text("Nothing scheduled yet, so you will hear about everything, all week.")
                .font(.system(size: Metrics.labelSize)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .frame(minHeight: Metrics.rowHeight)
        .allowsHitTesting(false)
    }
}

/// One window, on one line: enabled, days, when, level, remove.
///
/// Two lines was the first attempt and it read as two settings rather than
/// one. The hours hide behind a popover for the same reason — inline pickers
/// are wide, and most of the time you want to see *which days*, not re-read a
/// time you already set.
struct WindowRow: View {
    @Binding var window: QuietWindow
    let remove: () -> Void
    @State private var editing = false

    private var allDay: Bool { window.startMinute == window.endMinute }

    /// Everything on one line has to survive the window's minimum width, and
    /// it did not: the switch, seven days, the hours, the level and the delete
    /// came to more than the card once the type scale went up, and the row ran
    /// out past the card's edge. The widths below are budgeted against the
    /// card's width at the 880pt minimum window, with the widest possible
    /// time — a window that crosses midnight, so "22:00 – 08:00 +1".
    var body: some View {
        HStack(spacing: 8) {
            // Every control here is one of several identical ones down the
            // card, so each says which window it belongs to. The hours are the
            // only thing that distinguishes one row from another out loud —
            // the days are seven separate controls and the level is a value,
            // not a name.
            Toggle("", isOn: $window.enabled).toggleStyle(.switch).labelsHidden()
                .controlSize(.mini)
                .accessibilityLabel("Quiet window \(summary)")
            DayPicker(days: $window.days)
            Button { editing.toggle() } label: {
                HStack(spacing: 4) {
                    Text(summary)
                        .font(.system(size: Metrics.labelSize)).monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 124, alignment: .leading)
            .accessibilityLabel("Hours for this quiet window")
            .accessibilityValue(summary)
            .popover(isPresented: $editing, arrowEdge: .bottom) { schedule }

            Spacer(minLength: 8)

            Picker("", selection: $window.level) {
                Text(Attention.quiet.rawValue).tag(Attention.quiet)
                Text(Attention.offDuty.rawValue).tag(Attention.offDuty)
            }
            .labelsHidden().frame(width: 96)
            .accessibilityLabel("How quiet, \(summary)")

            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .accessibilityLabel("Remove the quiet window \(summary)")
        }
        .padding(.vertical, 9)
        .frame(minHeight: Metrics.rowHeight)
        .opacity(window.enabled ? 1 : 0.5)
    }

    private var summary: String {
        if allDay { return "All day" }
        let text = "\(clock(window.startMinute)) – \(clock(window.endMinute))"
        return window.startMinute > window.endMinute ? text + " +1" : text
    }

    private func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("All day", isOn: Binding(
                get: { allDay },
                set: { on in
                    if on { window.startMinute = 0; window.endMinute = 0 }
                    else { window.startMinute = 22 * 60; window.endMinute = 8 * 60 }
                }))
                .toggleStyle(.checkbox)
            if !allDay {
                HStack(spacing: 8) {
                    TimeField(minutes: $window.startMinute, label: "Quiet from")
                    Text("to")
                        .font(.system(size: Metrics.labelSize))
                        .foregroundStyle(.secondary)
                    TimeField(minutes: $window.endMinute, label: "Quiet until")
                }
                if window.startMinute > window.endMinute {
                    Note("This window crosses midnight. It belongs to the day it starts "
                         + "on, so a Friday window is still running at 02:00 on Saturday.")
                        .frame(width: 210)
                }
            }
        }
        .padding(14)
    }
}

// MARK: - Projects

struct ProjectsPage: View {
    @ObservedObject var model: SettingsModel
    let live: LiveState
    /// Which row's name field has the keyboard. Return clears it, which is how
    /// a field that saves as you type can still acknowledge Return.
    @FocusState private var editing: String?

    var body: some View {
        SettingsPageBody(page: .projects) {
            Card(title: "Your projects", blurb: "The name you type here is used everywhere, including on "
                        + "your phone. Turn on \u{201C}Name only\u{201D} to keep the conversation "
                        + "title private, so only the project name is sent.") {
                if projects.isEmpty {
                    Text("No projects yet. Open a Claude Code session and it will "
                         + "show up here.")
                        .font(.system(size: Metrics.labelSize))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, Metrics.blockPadding)
                } else {
                    header
                    ForEach(projects, id: \.self) { project in
                        Divider()
                        row(project)
                    }
                }
            }
        }
    }

    /// The header has to carry a column for the forget button too, even though
    /// it never has one to show.
    ///
    /// That button was the whole misalignment: the row ended with it and the
    /// header did not, so every header sat one button plus one gap to the
    /// right of the content it named. Correcting the checkbox by a few points
    /// is aimed at the wrong thing entirely.
    private var header: some View {
        HStack(spacing: 12) {
            Text("Project")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Name only")
                .frame(width: ProjectsPage.nameOnlyColumn, alignment: .center)
            Text("Level")
                .frame(width: ProjectsPage.levelColumn, alignment: .center)
            Color.clear.frame(width: ProjectsPage.forgetColumn, height: 1)
        }
        .font(.system(size: Metrics.noteSize))
        .foregroundStyle(.secondary)
        .padding(.top, Metrics.blockPadding)
        .allowsHitTesting(false)
    }

    private static let nameOnlyColumn: CGFloat = 76
    private static let levelColumn: CGFloat = 112
    private static let forgetColumn: CGFloat = 16

    /// Every project the daemon has ever seen, most recent first, with the
    /// running ones and the ruled ones guaranteed present.
    ///
    /// It used to be `live ∪ ruled`, sorted by name, which meant the page was
    /// empty whenever nothing was running — you could only configure a project
    /// while a session in it happened to be open, and a row left at its
    /// defaults disappeared with the terminal that produced it.
    private var projects: [String] {
        ProjectRoster.shared.known(
            live: live.projects,
            ruled: Set(model.config.attention.projects.map(\.id)))
    }

    private func isLive(_ project: String) -> Bool { live.projects.contains(project) }

    private func named(_ project: String) -> String { rule(project).displayName ?? "" }

    private func row(_ project: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    TextField(project, text: displayName(project))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: Metrics.labelSize))
                        .focused($editing, equals: project)
                        // Every keystroke already saves, so Return has nothing
                        // left to commit — which is exactly why it felt broken.
                        // Dropping focus is the acknowledgement: the field
                        // stops looking like something you are still filling in.
                        .onSubmit { editing = nil }
                        // A `TextField`'s placeholder is not its label, and the
                        // placeholder here is the folder name — so an empty
                        // field announced the project and never said what you
                        // would be typing into it.
                        .accessibilityLabel("Name shown for \(project)")
                    if !named(project).isEmpty {
                        Button {
                            write(project) { $0.displayName = nil }
                            editing = nil
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Go back to the folder name")
                        .accessibilityLabel("Go back to the folder name for \(project)")
                    }
                }
                HStack(spacing: 6) {
                    Text(project)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    // Running now, or a name the roster is holding for you.
                    // Without this the page cannot say why a project it has
                    // never mentioned before is suddenly on the list.
                    if isLive(project) {
                        Text("running")
                            .font(.system(size: Metrics.noteSize))
                            .foregroundStyle(Palette.accent)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Column headers are a visual convention: nothing associates one
            // with the controls beneath it, so each row repeats its column's
            // name and says which project it is for.
            Toggle("", isOn: hideTitle(project))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Name only, for \(project)")
                .frame(width: ProjectsPage.nameOnlyColumn, alignment: .center)
                // No optical offset here, unlike the Notifications table.
                // Measured, not assumed: this checkbox already sits dead centre
                // of its column, and correcting it moved it 4.75pt off. The
                // quirk is not a property of the control, it is a property of
                // how the row around it distributes space — so it gets
                // measured per table rather than assumed.

            Picker("", selection: level(project)) {
                ForEach(Attention.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: ProjectsPage.levelColumn)
            .accessibilityLabel("Level for \(project)")

            // Only for the ones being remembered. Forgetting a project that is
            // running would put it straight back on the next tick, which reads
            // as a button that does not work.
            Button {
                write(project) { $0 = ProjectRule(id: project) }
                ProjectRoster.shared.forget(project)
            } label: {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(isLive(project))
            .opacity(isLive(project) ? 0 : 1)
            .frame(width: ProjectsPage.forgetColumn)
            .help("Forget this project")
            .accessibilityLabel("Forget \(project)")
            // Hidden by opacity while a project is running, and an invisible
            // button is still in the reading order — so it is taken out of the
            // tree rather than merely faded.
            .accessibilityHidden(isLive(project))
        }
        .padding(.vertical, 9)
        .frame(minHeight: Metrics.rowHeight)
    }

    private func rule(_ id: String) -> ProjectRule {
        model.config.attention.projects.first { $0.id == id } ?? ProjectRule(id: id)
    }

    private func write(_ id: String, _ change: (inout ProjectRule) -> Void) {
        var rule = self.rule(id)
        change(&rule)
        var all = model.config.attention.projects.filter { $0.id != id }
        // Keep the file free of rules that say nothing.
        if rule.level != .normal || rule.hideSessionTitle || rule.displayName?.isEmpty == false {
            all.append(rule)
        }
        model.config.attention.projects = all.sorted { $0.id < $1.id }
    }

    private func displayName(_ id: String) -> Binding<String> {
        Binding(get: { rule(id).displayName ?? "" },
                set: { value in write(id) { $0.displayName = value.isEmpty ? nil : value } })
    }

    private func hideTitle(_ id: String) -> Binding<Bool> {
        Binding(get: { rule(id).hideSessionTitle },
                set: { value in write(id) { $0.hideSessionTitle = value } })
    }

    private func level(_ id: String) -> Binding<Attention> {
        Binding(get: { rule(id).level }, set: { value in write(id) { $0.level = value } })
    }
}

// MARK: - Floating bar

struct BarPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPageBody(page: .bar) {
            Card { bar }
        }
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(label: "Show the floating bar") {
                Toggle("", isOn: Binding(
                    get: { model.config.bar.visible },
                    set: { model.config.bar.visible = $0 }))
                    .toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel("Show the floating bar")
            }
            Divider()
            SettingRow(label: "Direction",
                       help: "A column suits a screen corner. A row puts the names "
                             + "under the bulbs instead of beside them.") {
                Picker("", selection: Binding(
                    get: { model.config.bar.horizontal },
                    set: { model.config.bar.horizontal = $0 })) {
                    Text("Vertical").tag(false)
                    Text("Horizontal").tag(true)
                }
                .labelsHidden().frame(width: 140)
                .accessibilityLabel("Direction of the floating bar")
            }
            Divider()
            SettingRow(label: "Size") {
                HStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { model.config.bar.size },
                        set: { model.config.bar.size = $0 }), in: 14...36, step: 2)
                        .frame(width: 200)
                        .accessibilityLabel("Size of the floating bar")
                        .accessibilityValue("\(Int(model.config.bar.size)) points")
                    Text("\(Int(model.config.bar.size)) pt")
                        .font(.system(size: Metrics.labelSize)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            Divider()
            SettingRow(label: "Position",
                       help: "You can drag the bar anywhere. If it ends up under the "
                             + "notch, or on a monitor you have unplugged, this brings it back.") {
                // "Reset" alone, out of the row's context, could be anything on
                // this page — the size, the direction, every setting in it.
                Button("Reset") { FloatingBarRenderer.resetPosition() }
                    .accessibilityLabel("Reset the floating bar's position")
            }
        }
    }
}

// MARK: - About

struct AboutPage: View {
    var body: some View {
        SettingsPageBody(page: .about) {
            Card {
                HStack(alignment: .top, spacing: 14) {
                    // Sized to the block of text beside it rather than to a
                    // number picked in isolation. At 56 it read as an avatar
                    // dropped next to a paragraph; at the paragraph's own
                    // height the two are one object.
                    Image(nsImage: AppIcon.image(size: 256))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Traffic Light").font(.system(size: 17, weight: .semibold))
                        Text("Ambient status for coding agents")
                            .font(.system(size: Metrics.labelSize))
                            .foregroundStyle(.secondary)
                        Text("Version \(Version.current)")
                            .font(.system(size: Metrics.noteSize))
                            .foregroundStyle(.secondary)
                        // One literal string, not a concatenation: `Text` only
                        // parses markdown when it is handed a literal, so a
                        // `+` here would print the brackets instead of making
                        // a link.
                        Text("Developed by [Supun Tharinda](https://supunte.dev), with Claude Code and OpenAI Codex")
                            .font(.system(size: Metrics.noteSize))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.vertical, Metrics.blockPadding)
            }

            Card(title: "What each signal means",
                 blurb: "The menu bar always shows the most urgent one across all "
                        + "your sessions, in this order.") {
                ForEach(Signal.allCases, id: \.self) { signal in
                    HStack(spacing: 8) {
                        SignalDot(signal: signal)
                        Text(signal.rawValue)
                            .font(.system(size: Metrics.labelSize))
                            .frame(width: 68, alignment: .leading)
                        Text(meaning(signal))
                            .font(.system(size: Metrics.labelSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    .frame(minHeight: Metrics.rowHeight)
                    .allowsHitTesting(false)
                    if signal != Signal.allCases.last { Divider() }
                }
            }

            Card(title: "Where your files are kept") {
                path("Settings", Paths.config)
                Divider()
                path("State", Paths.state)
                Divider()
                path("Projects", Paths.projects)
                Divider()
                path("Event log", Paths.events)
            }
        }
    }

    private func meaning(_ signal: Signal) -> String {
        switch signal {
        case .working: "getting on with it, nothing needed from you"
        case .asking: "waiting for your answer before it can carry on"
        case .done: "finished, and the work is ready for you to read"
        case .broken: "crashed, stuck, or asking for help, so go take a look"
        case .idle: "nothing claiming your attention right now"
        }
    }

    private func path(_ name: String, _ url: URL) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: Metrics.labelSize))
                .frame(width: 72, alignment: .leading)
            Text(Paths.display(url))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Show \(name) in the Finder")
        }
        .padding(.vertical, 9)
        .frame(minHeight: Metrics.rowHeight)
    }
}
