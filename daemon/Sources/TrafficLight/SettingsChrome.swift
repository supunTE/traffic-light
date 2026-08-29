import AppKit
import SwiftUI

/// The window's shell: a source list on the left, one page on the
/// right, in the shape macOS Settings has used since Ventura.
///
/// Sidebar rather than a tab strip because six tabs is past where a strip
/// starts truncating labels, and because the pages are not peers —
/// Notifications is where people go, About is where they end up once.
enum SettingsPage: String, CaseIterable, Identifiable {
    case notifications, chimes, quiet, projects, bar, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: "Notifications"
        case .chimes: "Chimes"
        case .quiet: "Quiet hours"
        case .projects: "Projects"
        case .bar: "Floating bar"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .notifications: "iphone.gen3"
        case .chimes: "speaker.wave.2"
        case .quiet: "moon"
        case .projects: "folder"
        case .bar: "square.stack"
        case .about: "info.circle"
        }
    }

    /// One line under the page title. Says what the page is *for*, so the page
    /// itself does not have to open with a paragraph.
    var blurb: String {
        switch self {
        case .notifications:
            "Choose what gets sent to your phone, and how loudly it arrives."
        case .chimes:
            "Sounds this Mac plays when something changes."
        case .quiet:
            "Set times of the week to go quiet. Outside them, everything works as usual."
        case .projects:
            "Give your projects friendlier names, and quieten one without affecting the others."
        case .bar:
            "The small bar that sits on top of your other windows."
        case .about:
            "Version, what each signal means, and where your files are kept."
        }
    }
}

// MARK: - Shared building blocks

/// True while the page is being drawn offscreen rather than shown in a window.
///
/// `ImageRenderer` has no viewport, so a `ScrollView` renders as nothing at
/// all. One environment flag lets the few views that depend on a viewport
/// substitute something that does not.
struct SettingsRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsRendering: Bool {
        get { self[SettingsRenderingKey.self] }
        set { self[SettingsRenderingKey.self] = newValue }
    }
}

/// A page: title, blurb, then content. Every page uses it, so the type size,
/// the gap under the title and the content inset are decided once.
struct SettingsPageBody<Content: View>: View {
    let page: SettingsPage
    @Environment(\.settingsRendering) private var rendering
    @ViewBuilder var content: Content

    var body: some View {
        if rendering {
            inner
        } else {
            // Only a scroll view when one is needed. macOS 15's SwiftUI turns
            // every scroll event over a ScrollView into thousands of hit tests
            // — Apple's own System Settings stutters the same way — so a page
            // that fits should not install one at all. `ViewThatFits` picks
            // the plain stack whenever the page has room.
            ViewThatFits(in: .vertical) {
                inner
                ScrollView { inner }
            }
            // Pinned to the top, outside the measurement. A stack shorter than
            // the pane is centred by default, which put the heading halfway
            // down the window and left a band of nothing above it. The frame
            // sits outside `ViewThatFits` on purpose: inside, an infinite
            // height would always "fit" and the scroll branch could never be
            // chosen.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionGap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title)
                    .font(.system(size: 22, weight: .semibold))
                Text(page.blurb)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .allowsHitTesting(false)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.bottom, Metrics.pagePadding)
        .padding(.top, Metrics.pageTop)
    }
}

/// Measured off System Settings rather than invented, because a window that is
/// almost the system's is worse than one that plainly is not — the near miss is
/// what reads as amateur.
///
/// The type scale is the substance of it. This window used to set text at 9,
/// 10, 11, 12, 15 and 22 point; System Settings uses **two** sizes for
/// everything inside a group — 13 for anything you read as a label or a value,
/// 11 for the sentence explaining it — and nothing at all below 11. Six sizes
/// was not a hierarchy, it was six decisions taken separately, and it made the
/// whole window read a size too small.
enum Metrics {
    static let pagePadding: CGFloat = 20
    /// More than the sides, because the window has a transparent title bar and
    /// the detail pane runs underneath it — 20 would put the heading level
    /// with the close button. 32 clears a 28pt title bar with 4 to spare,
    /// which is as high as the heading can go before it starts to look like
    /// it is colliding with the window chrome rather than sitting under it.
    static let pageTop: CGFloat = 32
    static let sectionGap: CGFloat = 20
    static let cardRadius: CGFloat = 10
    /// Horizontal inset inside a card. Vertical spacing is *not* here: rows
    /// carry their own height, which is what makes a divider run edge to edge
    /// between them instead of floating in a gap.
    ///
    /// 16, not 12. At 12 the labels sat close enough to the card's edge that
    /// the card read as a box drawn around the text rather than a surface the
    /// text sits on — most obvious on the wide rows, where a full-width table
    /// nearly touched both sides.
    static let cardPadding: CGFloat = 16
    /// The system's row rhythm. Every labelled row is at least this tall, so a
    /// card of one-line rows steps down the page evenly whatever is in them.
    static let rowHeight: CGFloat = 38
    /// For free-form blocks inside a card that are not rows — a table, a
    /// health strip — so they sit off the card edge by the same amount.
    static let blockPadding: CGFloat = 12
    /// A label, a value, a button title. The system control size.
    static let labelSize: CGFloat = 13
    /// The sentence under a label. The only other size in the window.
    static let noteSize: CGFloat = 11
}

/// A grouped card. One background, one radius, one border — defined here so no
/// page invents its own and lands a point off the others.
struct Card<Content: View>: View {
    var title: String?
    var blurb: String?
    /// Stretch to the tallest card beside it. Only for cards sharing a row:
    /// two cards of different heights side by side look like one of them
    /// failed to load.
    var equalHeight = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || blurb != nil {
                // Sentence case at label size, not tracked-out micro-caps.
                // "Notification Centre" in System Settings is the same size as
                // the labels below it and simply bolder — the group is named,
                // not stamped with a filing label. A blurb with no title is
                // allowed: some groups need the sentence and would only repeat
                // the page heading if made to carry a name as well.
                VStack(alignment: .leading, spacing: 2) {
                    if let title {
                        Text(title)
                            .font(.system(size: Metrics.labelSize, weight: .semibold))
                    }
                    if let blurb {
                        Text(blurb)
                            .font(.system(size: Metrics.noteSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 2)
                .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(maxWidth: .infinity,
                   maxHeight: equalHeight ? .infinity : nil, alignment: .topLeading)
            // No border. A white card on a warm off-white ground is already
            // separated; outlining it as well is the belt-and-braces look that
            // makes a window feel drawn rather than designed. The shadow is
            // almost nothing on purpose — enough to lift the edge, not enough
            // to notice as a shadow.
            .background(Palette.card,
                        in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        }
    }
}

/// A labelled row inside a card: label at the leading edge, control at the
/// trailing one.
///
/// The label used to sit in a fixed 96pt column with the control immediately
/// after it, which left every card's controls huddled against the left and a
/// third of the width empty. The system pushes them to the far edge, and that
/// is the single change that makes a card look like a card: one column of
/// words, one column of controls, the gap between them doing the work.
///
/// `SettingRow`, not `Row` — the model already owns that name for one line of
/// what a Renderer shows, and two `Row`s in one module is a coin toss.
struct SettingRow<Control: View>: View {
    let label: String
    var help: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: Metrics.labelSize))
                if let help {
                    Text(help)
                        .font(.system(size: Metrics.noteSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 9)
        .frame(minHeight: Metrics.rowHeight)
    }
}

/// Explanatory text under a control. Always the same size and colour, so an
/// aside never competes with a label.
struct Note: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: Metrics.noteSize))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            // Decoration, so it takes itself out of the hit-test tree. macOS 15
            // regressed SwiftUI scrolling into thousands of hit tests per
            // scroll event — 85 % of frame time in `_hitTestForEvent` — and the
            // count is what costs. Nothing here was ever clickable.
            .allowsHitTesting(false)
    }
}

/// Seven day circles: filled when on, hairline when off.
///
/// Sunday-first, matching `Calendar.weekday`, so the stored value needs no
/// translation at the one place it is read.
struct DayPicker: View {
    @Binding var days: Set<Int>
    private let letters = ["S", "M", "T", "W", "T", "F", "S"]

    /// Seven circles, a switch, a time, a level and a delete all share one row
    /// at the window's minimum width, so these are sized to the budget rather
    /// than to taste — 22 and 4 is what leaves room for the rest.
    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(letters[day - 1])
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .frame(width: 22, height: 22)
                        .background {
                            Circle().fill(on ? Palette.accent : Color.clear)
                        }
                        .overlay {
                            Circle().strokeBorder(
                                on ? Color.clear : Palette.hairline, lineWidth: 1)
                        }
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                // Spoken in full, and never as the letter. Two of the seven
                // are "S" and two are "T", so read aloud the row is "S, M, T,
                // W, T, F, S" — which identifies four of the days only by
                // their position in a row VoiceOver gives no position for.
                // The names come from the calendar rather than a list here, so
                // they follow the system's language and its first weekday.
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                // The only thing separating on from off is a filled circle.
                // `.isSelected` is how that reaches anyone not looking at it,
                // and the value says it in words for good measure.
                .accessibilityValue(on ? "On" : "Off")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }
}

/// A time of day as minutes from midnight, shown the way the system shows one.
struct TimeField: View {
    @Binding var minutes: Int
    /// Required, not defaulted: these come in pairs, and a pair of fields that
    /// both announce "time" is no better than a pair that announce nothing.
    let label: String

    var body: some View {
        DatePicker("", selection: Binding(
            get: {
                Calendar.current.date(bySettingHour: minutes / 60,
                                      minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }),
            displayedComponents: .hourAndMinute)
        .labelsHidden()
        .datePickerStyle(.field)
        .frame(width: 84)
        .accessibilityLabel(label)
    }
}

/// The real bulb, at reading size, wherever a list names a Signal.
///
/// It used to be a plain 8pt circle — the right colour and nothing else. Which
/// meant the window explaining the five Signals showed shapes you would never
/// see anywhere, while the menu bar, the floating bar and the preview panel
/// all drew the actual thing: SF Symbols with their ink centred, Idle a
/// dormant ring, Working an arc that turns. Naming a Signal beside a shape
/// that is not it is the one place a legend must not cut a corner.
///
/// `muted` is the combined "Working, Idle" row, which is two Signals and so
/// cannot show either. It draws Idle's resting ring: static, which is right
/// for a row about the states that never notify — Working's rotation in a
/// settings table would be motion advertising nothing.
struct SignalDot: View {
    let signal: Signal
    var muted = false
    @Environment(\.settingsRendering) private var rendering

    /// Sized against the 13pt label beside it rather than against the menu
    /// bar, which has its own scale.
    private let pointSize: CGFloat = 14

    var body: some View {
        Group {
            if rendering {
                // `ImageRenderer` draws SwiftUI, and an `NSViewRepresentable`
                // is not SwiftUI — it comes out empty. Offscreen renders fall
                // back to the plain dot so the page is still legible.
                Circle()
                    .fill(muted ? Color.clear : Color(signal.color))
                    .overlay {
                        if muted { Circle().strokeBorder(Color.secondary, lineWidth: 1) }
                    }
                    .frame(width: 8, height: 8)
            } else {
                LiveBulb(signal: muted ? .idle : signal, pointSize: pointSize)
            }
        }
        .frame(width: pointSize + 4, height: pointSize + 4)
        .allowsHitTesting(false)
        // Everywhere this appears, the Signal's name is written next to it —
        // that is what a legend is. Announcing the bulb as well would say
        // every Signal twice, and the second time as an unnamed image.
        .accessibilityHidden(true)
    }
}

/// One line of the health strip.
struct HealthLine: View {
    let ok: Bool
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: Metrics.labelSize))
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(name)
                .font(.system(size: Metrics.labelSize))
                .frame(width: 56, alignment: .leading)
            Text(detail)
                .font(.system(size: Metrics.labelSize))
                .foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
        // Read as one sentence rather than three fragments, and with the state
        // said in words. Whether a line is good news is carried by a green tick
        // against an orange exclamation mark — two channels on screen, and
        // neither of them reaches anyone who is not looking at it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(ok ? "working" : "not working"). \(detail)")
    }
}
