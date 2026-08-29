import AppKit
import SwiftUI

/// The Settings window, opened by the daemon itself.
///
/// In-process on purpose. `Config.load()` reads the whole struct and `write()`
/// puts the whole struct back, so two programs each holding a copy means the
/// second to save silently reverts the first — and the daemon writes
/// `config.json` by itself during normalise-on-load. One writer is the only
/// arrangement where that cannot happen. The floating bar is already an
/// `NSPanel` in this process, so a window here is the third surface rather
/// than a new capability.
@MainActor
enum Settings {
    private static var window: NSWindow?
    private static var watcher: NSObjectProtocol?

    static func show(config: ConfigStore, snapshot: @escaping () -> Snapshot,
                     quitsOnClose: Bool = false) {
        if let window {
            focus(window)
            return
        }

        let view = SettingsView(model: SettingsModel(config: config), snapshot: snapshot)
        let window = NSWindow(
            // Wider than it was. Notifications puts Topic and Health side by
            // side, and below ~880 the topic card cannot hold its field and
            // two buttons on one line.
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Traffic Light"
        // The sidebar runs under the title bar, which is what makes a source
        // list read as part of the window rather than a panel inside it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("traffic-light-settings")
        window.center()

        // The daemon is `.accessory` — no Dock icon, which is what lets a bare
        // binary behave like a menu bar app. A window you are meant to type
        // into needs `.regular` while it is open, and the policy goes back
        // when it closes, or the Dock keeps an icon for a window that is gone.
        watcher = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                // `queue: .main` means this always arrives on the main thread,
                // but the closure's type is `@Sendable` and carries none of
                // that — so every line below reads as main-actor state touched
                // from somewhere unknown. Asserting the isolation says what the
                // line above already guarantees, and is the whole difference
                // between a clean build and three warnings the installer used
                // to print at anyone installing this.
                MainActor.assumeIsolated {
                    Settings.window = nil
                    if let watcher { NotificationCenter.default.removeObserver(watcher) }
                    Settings.watcher = nil
                    if quitsOnClose { NSApp.terminate(nil) }
                    // Goes with the window. An accessory app shows no menu bar,
                    // so leaving it would be invisible rather than wrong — but
                    // the menu exists to serve this window and outliving it is
                    // how a stale ⌘Q ends up pointed at nothing.
                    NSApp.mainMenu = nil
                    NSApp.setActivationPolicy(.accessory)
                }
            }

        Settings.window = window
        focus(window)
    }

    private static func focus(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppIcon.image(size: 512)
        installMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The daemon has no main menu — it is a status item and two windows — and
    /// key equivalents live in one. Without this, ⌘Q and ⌘W do nothing while
    /// Settings is focused and the window can only be closed with the mouse.
    /// Worse and less obvious: ⌘C, ⌘V and ⌘A are routed through the Edit menu
    /// too, so the project name and quiet-hours fields could not be pasted
    /// into. The status item's menu is not a main menu and its shortcuts only
    /// fire while it is open, so it never covered any of this.
    ///
    /// **⌘Q closes the window rather than quitting.** Not the usual meaning,
    /// and chosen deliberately: this is a background daemon with no Dock icon,
    /// so a reflex ⌘Q aimed at a settings window would stop the light with
    /// nothing left on screen to say so, and getting it back means knowing to
    /// relaunch. Quitting stays a deliberate act — the item below it here, and
    /// the one in the status menu.
    private static func installMenu() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        let app = NSMenuItem()
        app.submenu = NSMenu(title: "Traffic Light")
        app.submenu?.addItem(withTitle: "Close Settings",
                             action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")
        app.submenu?.addItem(.separator())
        // No key equivalent, on purpose: it is the one thing here you should
        // not be able to do by muscle memory.
        app.submenu?.addItem(withTitle: "Quit Traffic Light",
                             action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        main.addItem(app)

        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        let editItems: [(String, String, String)] = [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("", "", ""),
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
            ("Select All", "selectAll:", "a")
        ]
        for (title, selector, key) in editItems {
            if title.isEmpty { edit.submenu?.addItem(.separator()); continue }
            edit.submenu?.addItem(withTitle: title, action: NSSelectorFromString(selector),
                                  keyEquivalent: key)
        }
        main.addItem(edit)

        let window = NSMenuItem()
        window.submenu = NSMenu(title: "Window")
        window.submenu?.addItem(withTitle: "Close",
                                action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.submenu?.addItem(withTitle: "Minimize",
                                action: #selector(NSWindow.performMiniaturize(_:)),
                                keyEquivalent: "m")
        main.addItem(window)

        NSApp.mainMenu = main
        NSApp.windowsMenu = window.submenu
    }

    /// `traffic-light settings` — the window on its own, for working on it.
    /// Not in `--help`, for the same reason `icon` is not: a command nobody
    /// needs is still a command everybody has to read past.
    static func runStandalone() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let config = ConfigStore()
        show(config: config, snapshot: { Store.loadSnapshot() }, quitsOnClose: true)
        app.run()
    }
}

/// Holds the config being edited and writes every change straight through.
///
/// There is no Save button, and that is deliberate: the daemon re-reads the
/// file within a second, so a change you make is a change you can hear. A form
/// you have to submit would break the one thing that makes chimes choosable.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config { didSet { commit() } }
    private let store: ConfigStore
    private var writing = false

    init(config store: ConfigStore) {
        self.store = store
        self.config = store.current
    }

    /// Writes this window's copy, but never over a snooze taken elsewhere.
    ///
    /// The window holds a whole `Config` and writes all of it on every change.
    /// The status menu writes the same file directly. So taking *Quiet for an
    /// hour* from the menu and then touching any control here within the
    /// two-second poll wrote the pre-snooze copy back, and the snooze silently
    /// vanished. The menu owns exactly one field, so exactly one field is
    /// re-read before writing.
    private func commit() {
        guard !writing else { return }
        writing = true
        store.reloadIfChanged()
        let onDisk = store.current.attention.snooze
        if onDisk != config.attention.snooze {
            config.attention.snooze = onDisk
        }
        config.write()
        store.reloadIfChanged()
        writing = false
    }

    /// Re-read from disk — for the values the daemon changes on its own, like
    /// a topic backfill, or a snooze taken from the menu while this is open.
    ///
    /// Gated on the file's modification date, which `reloadIfChanged` already
    /// tracks. The first version compared `encoded() != encoded()`, which
    /// serialised the entire config twice a tick and then, on a match,
    /// republished it — invalidating every view on screen for no change at
    /// all. A settings window that redraws itself twice a second is a settings
    /// window that scrolls badly.
    func refresh() {
        guard store.reloadIfChanged() else { return }
        writing = true
        config = store.current
        writing = false
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let snapshot: () -> Snapshot
    /// Which page to open on. Only `SettingsShots` passes anything but the
    /// default: it renders one window per page and cannot click a sidebar.
    var initialPage: SettingsPage = .notifications
    @State private var page: SettingsPage = .notifications
    /// What the window actually reads out of the daemon's state, and nothing
    /// more.
    ///
    /// Holding the whole `Snapshot` here meant every tick that touched
    /// `state.json` — which is every tick while a session is running —
    /// republished it, and SwiftUI rebuilt the entire page: sidebar, cards and
    /// fifteen AppKit-backed controls, twice a second, while you were trying
    /// to scroll them. Derived values change far less often than the file
    /// does, so most ticks now change nothing and publish nothing.
    @State private var live = LiveState()
    /// Held, not built in `body`. Constructing the publisher inline handed
    /// `onReceive` a new timer on every re-evaluation, restarting the two
    /// seconds each time — so while anything republished faster than that
    /// (a slider drag, typing a project name) the tick never fired at all and
    /// the health strip quietly froze.
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .frame(minWidth: 520)
                // Opaque, so the compositor is not blending a tall scrolling
                // page against the sidebar's vibrancy on every frame.
                .background(Palette.window)
        }
        .navigationSplitViewStyle(.balanced)
        // One accent for the whole window: selection, switches, checkboxes,
        // the filled day, every tinted button. Set once here rather than at
        // each control, because a control that quietly kept the system accent
        // is exactly the one nobody notices until it is on someone else's Mac
        // with a pink highlight colour.
        .tint(Palette.accent)
        // The minimum is the tallest page, not an arbitrary floor. `ViewThatFits`
        // installs a ScrollView only when the content does not fit, and on
        // macOS 15 a ScrollView is where the hit-test regression lives — so the
        // window is not allowed to shrink to a size that would summon one.
        .frame(minWidth: 880, minHeight: 700)
        .onAppear {
            page = initialPage
            live = LiveState(snapshot())
        }
        .onReceive(refresh) { _ in
            model.refresh()
            let fresh = LiveState(snapshot())
            if fresh != live { live = fresh }
        }
    }

    private var sidebar: some View {
        List(selection: $page) {
            Section {
                ForEach(SettingsPage.allCases.filter { $0 != .about }) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            Section {
                Label(SettingsPage.about.title, systemImage: SettingsPage.about.symbol)
                    .tag(SettingsPage.about)
            }
        }
        .listStyle(.sidebar)
        // The list's own vibrancy is what makes the sidebar take its colour
        // from the desktop behind it. Hidden, so the tint below is the one
        // that shows and the window looks the same on every wallpaper.
        .scrollContentBackground(.hidden)
        .background(Palette.sidebar)
        // One width, not a range. A range is what makes the divider draggable,
        // and there is nothing in a six-item source list worth resizing for —
        // the only thing dragging it achieves is a sidebar that no longer fits
        // "Notifications".
        .navigationSplitViewColumnWidth(196)
        .safeAreaInset(edge: .top, spacing: 0) { brand }
    }

    /// The mark and the name above the list. A settings window with a
    /// transparent title bar has an empty strip at the top otherwise, and an
    /// empty strip reads as a rendering fault rather than as space.
    private var brand: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIcon.image(size: 64))
                .resizable().frame(width: 22, height: 22)
            Text("Traffic Light")
                .font(.system(size: Metrics.labelSize, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var detail: some View {
        SettingsPage.view(page, model: model, live: live)
    }
}

extension SettingsPage {
    /// Which view a page is, decided once.
    ///
    /// The window and the screenshot renderer both need this, and each had its
    /// own copy of the switch. Adding a page compiled cleanly with only one of
    /// them updated — the other kept a stale arm, so the new page appeared in
    /// the sidebar and was invisible to every capture of it.
    @ViewBuilder
    static func view(_ page: SettingsPage, model: SettingsModel,
                     live: LiveState) -> some View {
        switch page {
        case .notifications: NotificationsPage(model: model, live: live)
        case .chimes: ChimesPage(model: model)
        case .quiet: QuietPage(model: model)
        case .projects: ProjectsPage(model: model, live: live)
        case .bar: BarPage(model: model)
        case .about: AboutPage()
        }
    }
}

/// Renders each page to a PNG without opening a window.
///
/// `ImageRenderer` draws the view tree offscreen, so this needs no Screen
/// Recording permission and no Space to be frontmost — so a page can be
/// rendered on a machine with no one at the keyboard.
@MainActor
enum SettingsShots {
    /// The real window, drawn by AppKit, one PNG per page.
    ///
    /// `ImageRenderer` — what `write(to:)` below uses — draws SwiftUI and
    /// nothing else, so every `Toggle`, `Picker`, `Slider` and `Button` comes
    /// out as an empty box. That is fine for judging spacing and useless for
    /// judging the window: a page of empty boxes shows the layout and none of
    /// the controls that give it meaning.
    ///
    /// `cacheDisplay(in:to:)` asks the view hierarchy to draw itself into a
    /// bitmap. It is not a screen capture: no Screen Recording permission,
    /// nothing of the desktop in the frame, and every AppKit control renders
    /// exactly as it does in the window — because it *is* the window.
    ///
    /// One window per page, because the sidebar selection is `@State` and
    /// there is nobody here to click it.
    static func writeWindowShots(to directory: String) {
        let config = ConfigStore()
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // `NSApplication.shared`, not `NSApp`: the latter is nil until the
        // former has been touched once, and nothing in this path has.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        for page in SettingsPage.allCases {
            let model = SettingsModel(config: config)
            let view = SettingsView(model: model, snapshot: { Store.loadSnapshot() },
                                    initialPage: page)
            let window = NSWindow(
                // Taller than the window opens by default, so a long page is
                // captured whole rather than cropped at the fold — About runs
                // past 700pt and would otherwise summon a scroll view and be
                // photographed halfway.
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 940),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: view)
            // Key and active, not merely on screen. An inactive window draws
            // every control in its unfocused grey — the switch, the sidebar
            // selection, the checkboxes — so an image of it shows none of the
            // colour the window actually has.
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)

            // SwiftUI needs a display cycle before any of this exists, and the
            // AppKit controls inside it need another to finish laying out.
            // Pumping the run loop is the only way to get one without an
            // `app.run()` that never returns.
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))

            guard let content = window.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            else { continue }
            content.cacheDisplay(in: content.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: folder.appending(path: "\(page.rawValue).png"))
            }
            window.orderOut(nil)
        }

        print("captured \(SettingsPage.allCases.count) pages to \(directory)")
    }

    static func write(to directory: String) {
        let config = ConfigStore()
        let model = SettingsModel(config: config)
        let snapshot = { Store.loadSnapshot() }
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for page in SettingsPage.allCases {
            let view = SettingsPage.view(page, model: model, live: LiveState(snapshot()))
                .environment(\.settingsRendering, true)
                .frame(width: 592, alignment: .topLeading)
                .background(Palette.window)
                .tint(Palette.accent)
            render(view, to: folder.appending(path: "\(page.rawValue).png"))
        }

        print("wrote \(SettingsPage.allCases.count) images to \(directory)")
    }

    private static func render(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

/// The handful of facts the Settings window shows about a running daemon.
///
/// `Equatable`, and deliberately small: the window compares one of these
/// against the last, and only redraws when a number a human can see has
/// actually changed. `state.json`'s modification date changes every second a
/// session is alive; "three sessions reporting" does not.
struct LiveState: Equatable {
    var stateAge: Int = 999
    var reporting: Int = 0
    var projects: [String] = []

    init() {}

    init(_ snapshot: Snapshot) {
        // Rounded to whole seconds, so a fractional age cannot republish this
        // on every tick by itself.
        stateAge = Int(Date().timeIntervalSince1970 - snapshot.updated)
        let rows = Store.rows(from: snapshot)
        reporting = rows.filter(\.reporting).count
        projects = Array(Set(rows.map(\.project))).sorted()
    }
}
