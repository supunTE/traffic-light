import AppKit

extension Signal {
    /// System colours rather than fixed hex: they are the only ones
    /// Apple adjusts for light and dark menu bars, for increased contrast, and
    /// for the colour-filter accessibility modes.
    var color: NSColor {
        switch self {
        // Red, amber, green are a traffic light, and mean here exactly what
        // they mean at a junction: stop, wait, go. That is the whole reason
        // the tool is called this, and it costs nothing to honour.
        case .broken: .systemRed
        case .asking: .systemOrange
        case .done: .systemGreen
        // Purple sits outside the metaphor on purpose: Working is the state a
        // junction has no lamp for, and the ring's motion already says
        // "in progress" — so the colour is free to be the one that is not
        // part of the sequence.
        case .working: .systemPurple
        // White: Idle means nothing is happening, and a light that has to
        // work to be seen is the right light for that.
        case .idle: .white
        }
    }

    /// Tinted SF Symbol on a square canvas, positioned so the *ink* is centred.
    ///
    /// Not a template image — a template would be forced to the menu bar's
    /// single foreground colour, which is exactly the information we are
    /// trying to convey.
    ///
    /// The re-centring is not fussiness. SF Symbols are laid out to sit on a
    /// text baseline, so the drawn shape is not centred inside the image box
    /// it comes in: `circle.fill` at 12pt has 1.0pt of padding on its left and
    /// 1.8pt on its right. Centring the image view centres the *box*, which
    /// leaves the dot visibly off in a 32pt panel where it is the only thing
    /// on screen.
    func image(pointSize: CGFloat = 13) -> NSImage? {
        // Working is drawn, not a symbol — this is its still form, used in
        // menus where nothing animates.
        if self == .working || self == .idle {
            return Bulb.ringImage(color: color, pointSize: pointSize,
                                  resting: self == .idle)
        }

        // Deliberately *not* `paletteColors`. The `.fill` symbols carry their
        // glyph as a knockout — the tick in `checkmark.circle.fill` is a hole
        // in the disc, not a shape drawn on top — and a palette colour fills
        // every layer including that hole, collapsing the symbol into a plain
        // coloured blob. Measured: centre alpha 0.00 plain, 1.00 with a
        // palette. So the symbol is rendered as-is and tinted with
        // `.sourceAtop`, which paints only where ink already exists and leaves
        // the holes alone.
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: symbolName,
                                   accessibilityDescription: rawValue)?
            .withSymbolConfiguration(config) else { return nil }
        symbol.isTemplate = true

        let offset = Signal.inkOffset(of: symbol, key: "\(symbolName)@\(pointSize)")
        let side = ceil(max(symbol.size.width, symbol.size.height))
        let tint = color
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            symbol.draw(at: NSPoint(x: (side - symbol.size.width) / 2 - offset.x,
                                    y: (side - symbol.size.height) / 2 - offset.y),
                        from: .zero, operation: .sourceOver, fraction: 1)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// How far the drawn shape's centre sits from its image box's centre, in
    /// points, bottom-left origin. Rasterised once per symbol and size.
    private static var inkOffsets: [String: CGPoint] = [:]

    private static func inkOffset(of image: NSImage, key: String) -> CGPoint {
        if let cached = inkOffsets[key] { return cached }

        let scale = 4
        let width = Int(image.size.width) * scale
        let height = Int(image.size.height) * scale
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return .zero }
        rep.size = image.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .zero }

        let s = CGFloat(scale)
        let inkCentreX = (CGFloat(minX) + CGFloat(maxX + 1)) / 2 / s
        // colorAt uses a top-left origin; drawing uses bottom-left.
        let inkCentreY = image.size.height - (CGFloat(minY) + CGFloat(maxY + 1)) / 2 / s
        let offset = CGPoint(x: inkCentreX - image.size.width / 2,
                             y: inkCentreY - image.size.height / 2)
        inkOffsets[key] = offset
        return offset
    }
}

func makeUIRenderers(config: ConfigStore) -> [Renderer] {
    let app = NSApplication.shared
    // .accessory: no Dock icon, no menu bar of its own, still allowed a status
    // item and a floating panel. This is what lets a bare SwiftPM binary with
    // no .app bundle behave like a menu bar app.
    app.setActivationPolicy(.accessory)

    let menuBar = MenuBarRenderer(config: config)
    let floatingBar = FloatingBarRenderer(config: config)

    // Whether AppKit actually attached is invisible from outside the process,
    // and a status item that silently failed to appear looks exactly like a
    // daemon that is not running. Say so on stderr.
    FileHandle.standardError.write(Data("""
        traffic-light: screens=\(NSScreen.screens.count) \
        statusItemButton=\(menuBar.hasButton) \
        panelVisible=\(floatingBar.isVisible)

        """.utf8))

    return [menuBar, floatingBar]
}

func runLoop(headless: Bool) {
    if headless {
        RunLoop.main.run()
    } else {
        NSApplication.shared.run()
    }
}

// MARK: - Menu bar

final class MenuBarRenderer: NSObject, Renderer, NSMenuDelegate {
    private let config: ConfigStore
    /// Set by the daemon once the Store exists, so Settings can show live
    /// health without the renderer owning the Store.
    var snapshotProvider: () -> Snapshot = { Snapshot() }
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var lastAggregate: Signal?
    private var lastLevel: Attention?

    /// Activating the app is all this does, and here is why.
    ///
    /// `claude://resume?session=<uuid>` is real, the parameter name is
    /// right, and Claude.app accepts the id — but the route **imports** a CLI
    /// session rather than focusing a live one. It looks for `local_<uuid>`,
    /// and a Session already running in the app is not registered under that
    /// key, so the first click builds a second copy of the conversation and
    /// rewrites the transcript on the way past, stripping thinking blocks.
    /// Clicking again then finds the duplicate it just made and behaves
    /// perfectly, which is what makes this look like it works.
    ///
    /// There is no route that focuses an already-open session by its id, so
    /// this is not fixable from outside the app. Do not wire the deep link up
    /// again without checking that first.
    @objc func jump(_ sender: NSMenuItem) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.anthropic.claudefordesktop"
        }) else {
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.anthropic.claudefordesktop") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
            return
        }
        app.activate(options: [.activateAllWindows])
    }

    /// Two submenus rather than a Settings round trip: silence is
    /// something you want *now*, usually because a meeting just started.
    ///
    /// No status line anywhere in this menu — the dimmed bulb and the crossed
    /// circle carry it. A line saying "Silenced until 09:00" was considered
    /// and rejected as clutter, so the tick beside a duration and the "Turn
    /// back on" entry are how an active snooze is visible from here.
    private func snoozeItem(_ level: Attention, current: Attention) -> NSMenuItem {
        let item = NSMenuItem(title: "\(level.rawValue) for", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let snooze = config.current.attention.snooze
        let mine = snooze?.level == level && (snooze?.active(at: Date()) ?? false)

        if mine {
            let off = NSMenuItem(title: "Turn back on", action: #selector(endSnooze),
                                 keyEquivalent: "")
            off.target = self
            submenu.addItem(off)
            submenu.addItem(.separator())
        }

        for choice in SnoozeChoice.all(level: level) {
            let entry = NSMenuItem(title: choice.title, action: #selector(takeSnooze(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice
            submenu.addItem(entry)
        }
        item.submenu = submenu
        item.state = mine ? .on : .off
        return item
    }

    @objc private func takeSnooze(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SnoozeChoice else { return }
        write { $0.attention.snooze = Snooze(level: choice.level, until: choice.until()) }
    }

    @objc private func endSnooze() {
        write { $0.attention.snooze = nil }
    }

    @objc private func openSettings() {
        MainActor.assumeIsolated {
            Settings.show(config: config, snapshot: snapshotProvider)
        }
    }

    /// The one path by which the menu changes settings. Writing the whole
    /// struct is safe here and nowhere else: the daemon is the only writer.
    private func write(_ change: (inout Config) -> Void) {
        var updated = config.current
        change(&updated)
        updated.write()
        config.reloadIfChanged()
    }

    var hasButton: Bool { item.button != nil }

    private let bulb = BulbView(pointSize: 14)

    init(config: ConfigStore) {
        self.config = config
        super.init()
        item.menu = menu
        menu.delegate = self

        // A hosted view rather than button.image, so Working can actually
        // turn. But a status item whose content is a subview has nothing to
        // measure: the button reports no intrinsic size, macOS reserves no
        // width, and the next app's icon gets packed into the same slot — the
        // two draw on top of each other. A fully transparent image of the
        // right size gives the button real metrics; the bulb draws over it.
        //
        // A fixed `item.length` is not enough on its own, because the button
        // inside still lays out against nothing.
        item.length = NSStatusItem.variableLength
        item.button?.image = NSImage(size: NSSize(width: 18, height: 18),
                                     flipped: false) { _ in true }
        item.button?.imagePosition = .imageOnly

        if let button = item.button {
            bulb.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(bulb)
            NSLayoutConstraint.activate([
                bulb.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                bulb.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                bulb.widthAnchor.constraint(equalToConstant: 16),
                bulb.heightAnchor.constraint(equalToConstant: 16)
            ])
        }
        bulb.show(.idle)
    }

    func render(rows: [Row], aggregate: Signal, transitions: [Transition],
                attention: AttentionState) {
        let level = attention.global
        if aggregate != lastAggregate || level != lastLevel {
            // Off duty replaces the Signal outright rather than dimming it.
            // That is the honest rendering of "tell me nothing": red is
            // invisible too, and a crossed circle says so where a dimmed red
            // would look like a red you could still act on.
            if level.showsSignalInMenuBar {
                bulb.show(aggregate)
                item.button?.alphaValue = level.dimsMenuBar ? 0.4 : 1
                item.button?.toolTip = level == .quiet
                    ? "Traffic Light — \(aggregate.rawValue) · Quiet"
                    : "Traffic Light — \(aggregate.rawValue)"
            } else {
                bulb.showOffDuty()
                item.button?.alphaValue = 1
                item.button?.toolTip = "Traffic Light — Off duty"
            }
            lastAggregate = aggregate
            lastLevel = level
        }

        // Recorded, not built. Measured at 0.6 ms to rebuild, every second,
        // for a menu nobody is looking at — and on the main thread the
        // Settings window is trying to draw on. AppKit asks for the items when
        // it is about to show them, which is the only moment they matter.
        pending = (rows, level)
    }

    /// Builds the items, at the moment the menu is opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let (rows, level) = pending
        menu.removeAllItems()

        let reporting = rows.filter(\.reporting)
        let silent = rows.filter { !$0.reporting }

        if reporting.isEmpty {
            let empty = NSMenuItem(title: Wording.nothingConnected,
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for row in reporting {
            let entry = NSMenuItem(title: row.name,
                                   action: #selector(jump(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = row.sessionId
            entry.image = row.signal.image(pointSize: 11)
            // The raw hook event goes here rather than in the row: invisible
            // until you look, and the first thing you want when the light is
            // wrong — which the friendly wording has deliberately thrown away.
            entry.toolTip = [row.title, row.cwd, row.rawNote]
                .compactMap { $0 }.joined(separator: "\n")

            // Conversation title on top, project underneath. The title is what
            // this session is *about*; the project is where it is. When there
            // is no title the project takes the top line rather than leaving
            // a gap.
            let text = NSMutableAttributedString(
                string: row.headline,
                attributes: [.font: NSFont.menuFont(ofSize: 13),
                             .foregroundColor: NSColor.labelColor])
            text.append(NSAttributedString(
                string: "   \(row.note)",
                attributes: [.font: NSFont.menuFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]))
            if let subtitle = row.subtitle {
                text.append(NSAttributedString(
                    string: "\n\(subtitle)",
                    attributes: [.font: NSFont.menuFont(ofSize: 10),
                                 .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            entry.attributedTitle = text
            menu.addItem(entry)
        }

        // Sessions Claude Code is running that Traffic Light cannot see. Kept
        // as a single line below a rule: worth knowing the tool is not
        // watching everything, not worth the same visual weight as a Signal.
        if !silent.isEmpty {
            menu.addItem(.separator())
            let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            note.isEnabled = false
            note.attributedTitle = NSAttributedString(
                string: Wording.othersNotConnected(silent.count),
                attributes: [.font: NSFont.menuFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor])
            note.toolTip = silent.map { $0.cwd ?? $0.name }.joined(separator: "\n")
                + "\n\nInstall the plugin there, then reopen the session."
            menu.addItem(note)
        }
        menu.addItem(.separator())
        menu.addItem(snoozeItem(.quiet, current: level))
        menu.addItem(snoozeItem(.offDuty, current: level))
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Traffic Light",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    /// The last thing `render` saw. The menu is built from this on demand.
    private var pending: ([Row], Attention) = ([], .normal)
}

// MARK: - Floating bar

/// A column of bulbs, always on top, on every Space including over a
/// full-screen window — which is the heads-down case it exists for.
///
/// Collapsed it is only the lights: at a glance you want the answer, not a
/// list of names. Hovering expands it to say which session is which.
///
/// Two things stop the hover from flickering, and both matter. **The bulbs are
/// anchored to the right edge**, so expanding grows the panel leftward *behind*
/// them and never slides a bulb out from under the pointer — moving the thing
/// you are pointing at is what caused the oscillation in the first place. And
/// **collapsing is delayed and re-checked** against the real pointer position,
/// because AppKit emits a spurious exit whenever the panel resizes.
final class FloatingBarRenderer: Renderer {
    private let panel: NSPanel
    private let stack = NSStackView()
    private let container = HoverView()
    private var rowViews: [BulbRow] = []
    private var expanded = false
    private var collapseTimer: Timer?
    private var lastKey = ""

    /// The panel's top-right corner in screen coordinates, held as state
    /// rather than read back from `panel.frame`. During an animation the frame
    /// reports an intermediate value, so deriving the anchor from it moved the
    /// anchor a little on every expand — the panel walked across the screen
    /// one hover at a time.
    private var anchor: NSPoint = .zero
    private var isAnimating = false

    private let padding: CGFloat = 8
    /// Pulls the bulbs off the trailing edge by a couple of points.
    ///
    /// The arithmetic says they are already centred: the collapsed panel is
    /// `bulbSize + padding * 2` wide and the stack is pinned `padding` off the
    /// trailing edge, so a `bulbSize`-wide row lands with equal gaps. They do
    /// not read that way, which is the kind of thing an eye is right about and
    /// a calculation is not — the plate's rounded corners and the ring's
    /// unpainted centre both pull the apparent weight rightwards.
    ///
    /// Deliberately small, and deliberately its own constant: if it turns out
    /// to be one point too many, this is the only number to change.
    private let bulbNudge: CGFloat = 2
    /// What `bar.size` currently says, clamped to the slider's own range so a
    /// hand-edited config cannot ask for a two-point bulb or a panel the size
    /// of a window.
    private var bulbSize: CGFloat { min(max(config.current.bar.size, 14), 36) }
    private var horizontal: Bool { config.current.bar.horizontal }
    /// The axis the rows were laid out for, so a change to the setting rebuilds
    /// them. A BulbRow decides where its labels go at init and cannot be turned
    /// afterwards.
    private var builtHorizontal = false
    /// The size the rows on screen were actually built at, so a change to the
    /// slider is noticed rather than waited on: the rows are only rebuilt when
    /// their *count* changes, and resizing does not change the count.
    private var builtAtSize: CGFloat = 0
    /// Derived, not chosen. A hand-picked width leaves the lone bulb sitting
    /// a couple of points off centre, which is invisible in the code and
    /// obvious on screen — the collapsed panel is a bulb plus equal padding
    /// on both sides, and nothing else.
    /// The nudge is added rather than taken out of the existing padding, so
    /// the bulbs move left inside a slightly wider plate instead of ending up
    /// closer to its left edge than they were to its right.
    private var collapsedSize: CGFloat { bulbSize + padding * 2 + bulbNudge }
    /// Long enough to survive a resize-induced exit and a pointer clipping a
    /// corner, short enough that a deliberate move away feels immediate.
    private let collapseDelay: TimeInterval = 0.35
    private let config: ConfigStore

    var isVisible: Bool { panel.isVisible }

    init(config: ConfigStore) {
        self.config = config
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        // A plain layer, not an NSVisualEffectView. The `.hudWindow` material
        // is built for dark HUDs: in light appearance it renders as a pale
        // plate with a bright edge, which reads as a ring drawn around the
        // widget. No material means no edge it can draw.
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0
        container.applyBackground()

        stack.orientation = .vertical
        stack.alignment = .trailing          // bulbs line up on the right
        applyAxis()
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                            constant: -(padding + bulbNudge)),
            // Centred rather than pinned to the top: the panel height is
            // computed to fit, so centring is the same thing when it fits and
            // the correct thing when it does not.
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor,
                                       constant: padding / 2),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor,
                                           constant: padding)
        ])
        panel.contentView = container

        container.onHover = { [weak self] inside in
            inside ? self?.expand() : self?.scheduleCollapse()
        }
        moveToDefaultCorner()
        // Was written and never called, so Settings' Reset button posted a
        // notification with nothing on the other end — a button that did
        // exactly nothing, silently, which is the worst way for one to fail.
        observeReset()
        // Block-based, not selector-based: this is a plain Swift class, so a
        // #selector observer would register against an object that cannot
        // answer it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.panelMoved() }
        // Deliberately not ordered front here. The first render decides, and
        // until it runs there are no rows — showing it now is an empty bar on
        // screen for the first tick of every launch, and a permanent one if
        // nothing is running when the daemon starts.
    }

    func render(rows: [Row], aggregate: Signal, transitions: [Transition],
                attention: AttentionState) {
        // Only Sessions that actually report. A grey bulb for a project
        // without hooks would be indistinguishable from an idle one, and the
        // menu already says how many are unwatched.
        let visible = rows.filter(\.reporting)

        // One decision about whether the panel is on screen, made here.
        //
        // There used to be two, and they fought. The top of this method
        // ordered the panel in whenever `wanted` disagreed with
        // `panel.isVisible`; the bottom ordered it out when there were no rows
        // to show. So the last session ending hid the bar correctly, and then
        // the very next tick saw wanted=true against a hidden panel and put it
        // straight back — empty, because the render key had not changed, so
        // the early return below fired before anything could hide it again.
        // An empty bar, permanently, from the moment you closed your last
        // session. Off duty hides it entirely for its own reason: it is the
        // surface hardest to ignore, so leaving it up would make Off duty a
        // half-measure.
        let shouldShow = attention.global.barVisible
            && config.current.bar.visible
            && !visible.isEmpty
        guard shouldShow else {
            if panel.isVisible { panel.orderOut(nil) }
            // Forces a rebuild when something comes back, rather than matching
            // a key from before the panel went away.
            lastKey = ""
            return
        }

        // The size is part of what makes this render stale, not just the rows.
        // Without it here the early return below swallows a slider drag whole:
        // the sessions have not changed, so the key matches, so nothing is
        // rebuilt and the bar keeps the size it was born at.
        let key = visible.map { "\($0.sessionId)\($0.signal.rawValue)\($0.name)" }
            .joined() + "|\(bulbSize)|\(horizontal)"
        guard key != lastKey else { return }
        lastKey = key

        if visible.count != rowViews.count || builtAtSize != bulbSize
            || builtHorizontal != horizontal {
            applyAxis()
            rowViews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            rowViews = visible.map { _ in BulbRow(bulbSize: bulbSize, stacked: horizontal) }
            builtAtSize = bulbSize
            builtHorizontal = horizontal
            rowViews.forEach { stack.addArrangedSubview($0) }
            rowViews.forEach { $0.setShowName(expanded, animated: false) }
        }
        for (view, row) in zip(rowViews, visible) { view.apply(row) }

        // Laid out before it is shown, so the panel never appears at whatever
        // size it last had and then snaps.
        layout(animated: false)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: Hover

    private func expand() {
        collapseTimer?.invalidate()
        collapseTimer = nil
        guard !expanded else { return }
        expanded = true
        rowViews.forEach { $0.setShowName(true, animated: true) }
        layout(animated: true)
    }

    private func scheduleCollapse() {
        guard expanded, collapseTimer == nil else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: collapseDelay, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            self.collapseTimer = nil
            // Never trust the exit event on its own — a resize fires one while
            // the pointer has not moved at all. Ask where the pointer is.
            guard !NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false) else { return }
            self.expanded = false
            self.rowViews.forEach { $0.setShowName(false, animated: true) }
            self.layout(animated: true)
        }
    }

    /// Anchored at the top-right corner: the panel grows left and down, so the
    /// bulbs stay exactly where they were.
    private func layout(animated: Bool) {
        let gaps = CGFloat(max(0, rowViews.count - 1)) * 2
        let width: CGFloat
        let height: CGFloat
        if horizontal {
            // Along the row: the widths add up, the tallest sets the height.
            let widths = rowViews.reduce(0) { $0 + $1.fittingWidth }
            width = max(collapsedSize, widths + gaps + padding * 2)
            let tallest = rowViews.map(\.fittingHeight).max() ?? 0
            height = max(collapsedSize, tallest + padding)
        } else {
            let content = rowViews.map(\.fittingWidth).max() ?? 0
            width = expanded ? max(collapsedSize, content + padding * 2) : collapsedSize
            // Rows grow taller when they carry a project line, so sum them
            // rather than multiplying by a fixed row height.
            let rowsHeight = rowViews.reduce(0) { $0 + $1.fittingHeight }
            height = max(collapsedSize, rowsHeight + gaps + padding)
        }

        var frame = NSRect(x: anchor.x - width, y: anchor.y - height,
                           width: width, height: height)

        // Growing leftward must never push the panel off the edge it is
        // nearest. Clamp, and let the anchor stay where the user put it.
        if let screen = panel.screen ?? NSScreen.main {
            let limit = screen.visibleFrame
            frame.origin.x = max(limit.minX + 4, min(frame.origin.x, limit.maxX - width - 4))
            frame.origin.y = max(limit.minY + 4, min(frame.origin.y, limit.maxY - height - 4))
        }

        guard frame != panel.frame else { return }
        if animated {
            isAnimating = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in self?.isAnimating = false })
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// The user dragging the panel is the only thing that may move the anchor.
    private func panelMoved() {
        guard !isAnimating else { return }
        anchor = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
    }

    /// Settings asks for this by name; the renderer owns the geometry.
    private func observeReset() {
        NotificationCenter.default.addObserver(
            forName: .trafficLightResetBar, object: nil, queue: .main) { [weak self] _ in
                self?.moveToDefaultCorner()
            }
    }

    /// Turns the stack. Called at init and whenever the setting changes, since
    /// an NSStackView can be re-oriented in place even though its rows cannot.
    private func applyAxis() {
        stack.orientation = horizontal ? .horizontal : .vertical
        stack.alignment = horizontal ? .top : .trailing
    }

    private func moveToDefaultCorner() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        anchor = NSPoint(x: visible.maxX - 12, y: visible.maxY - 12)
        panel.setFrame(NSRect(x: anchor.x - collapsedSize, y: anchor.y - collapsedSize,
                              width: collapsedSize, height: collapsedSize), display: true)
    }
}

/// Reports pointer enter and exit. `.inVisibleRect` keeps the region correct
/// as the panel resizes, so the tracking area is installed once and never
/// rebuilt — rebuilding it on every geometry change is itself a source of
/// spurious enter/exit pairs.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    private var installed: NSTrackingArea?

    /// Re-resolved on every appearance change: a CGColor captured once does
    /// not follow the system between light and dark.
    func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(0.92).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard installed == nil else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        installed = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// One bulb with its labels to the left: conversation title on top, project
/// underneath in a smaller, dimmer face. The bulb is pinned to the trailing
/// edge and vertically centred, so it never moves when the text appears.
final class BulbRow: NSView {
    private let bulb: BulbView
    private let titleLabel = NSTextField(labelWithString: "")
    private let projectLabel = NSTextField(labelWithString: "")
    private let text = NSStackView()
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var showName = false

    /// Bigger than the menu bar's, on purpose. The menu bar dot sits in a
    /// row of system icons that set its scale; the floating bar is a thing
    /// you glance at from across the desk, and at 16pt the glyph inside a
    /// filled circle was too small to read at that distance.
    ///
    /// Set from `bar.size` rather than fixed. It was a `static let 22` and the
    /// Settings slider wrote `bar.size` to the config file where **nothing
    /// read it** — a control that persisted its value, survived a restart, and
    /// changed nothing on screen.
    static let defaultBulbSize: CGFloat = 22
    let bulbSize: CGFloat

    /// Both derived from the bulb, so a 36pt bulb gets a row it fits in. Fixed
    /// numbers here were the same bug waiting to happen from the other side.
    var collapsedHeight: CGFloat { bulbSize + 4 }
    private var expandedHeight: CGFloat { bulbSize + 12 }

    private var hasSubtitle: Bool { !projectLabel.isHidden }

    private var widestLabel: CGFloat {
        max(titleLabel.intrinsicContentSize.width,
            hasSubtitle ? projectLabel.intrinsicContentSize.width : 0)
    }

    var fittingWidth: CGFloat {
        guard showName else { return bulbSize }
        // Stacked, the labels sit under the bulb rather than beside it, so
        // they set the width outright instead of adding to it. Capped, because
        // one long conversation title should not decide how wide the whole bar
        // is.
        if stacked { return max(bulbSize, min(widestLabel, 160)) }
        return bulbSize + widestLabel + 6
    }

    var fittingHeight: CGFloat {
        if stacked {
            // `collapsedHeight`, not `bulbSize`. The vertical bar's rows are
            // bulbSize + 4 tall and these were bulbSize exactly, so the two
            // axes handed the same bulb a differently shaped box to sit in —
            // the one asymmetry between them, and the only candidate for a
            // 20pt bulb that does not look 20pt in both.
            guard showName else { return collapsedHeight }
            let lines = titleLabel.intrinsicContentSize.height
                + (hasSubtitle ? projectLabel.intrinsicContentSize.height : 0)
            return collapsedHeight + 2 + lines
        }
        return showName && hasSubtitle ? expandedHeight : collapsedHeight
    }

    /// Bulb above its labels rather than beside them. The horizontal bar
    /// needs it: laid out sideways, a name to the *left* of its bulb belongs
    /// to no column and reads as belonging to the bulb before it.
    let stacked: Bool

    init(bulbSize: CGFloat = BulbRow.defaultBulbSize, stacked: Bool = false) {
        self.bulbSize = bulbSize
        self.stacked = stacked
        bulb = BulbView(pointSize: bulbSize)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bulb.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = stacked ? .center : .right
        titleLabel.lineBreakMode = .byTruncatingHead

        projectLabel.font = .systemFont(ofSize: 10, weight: .regular)
        projectLabel.textColor = .secondaryLabelColor
        projectLabel.alignment = stacked ? .center : .right
        projectLabel.lineBreakMode = .byTruncatingHead

        text.orientation = .vertical
        text.alignment = stacked ? .centerX : .trailing
        text.spacing = 0
        text.addArrangedSubview(titleLabel)
        text.addArrangedSubview(projectLabel)
        text.alphaValue = 0

        addSubview(text)
        addSubview(bulb)

        widthConstraint = widthAnchor.constraint(equalToConstant: bulbSize)
        heightConstraint = heightAnchor.constraint(equalToConstant: collapsedHeight)
        var shared: [NSLayoutConstraint] = [
            widthConstraint,
            heightConstraint,
            bulb.widthAnchor.constraint(equalToConstant: bulbSize),
            // BulbView draws into its layer and has no intrinsic size, unlike
            // the NSImageView it replaced — without this it lays out zero-high
            // and the bar shows an empty box.
            bulb.heightAnchor.constraint(equalToConstant: bulbSize)
        ]
        if stacked {
            shared += [
                bulb.centerXAnchor.constraint(equalTo: centerXAnchor),
                // Centred in the row's own top `collapsedHeight`, matching how
                // the vertical bar centres it, rather than jammed against the
                // top edge.
                bulb.topAnchor.constraint(equalTo: topAnchor,
                                          constant: (collapsedHeight - bulbSize) / 2),
                text.topAnchor.constraint(equalTo: bulb.bottomAnchor, constant: 2),
                text.centerXAnchor.constraint(equalTo: centerXAnchor),
                text.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
            ]
        } else {
            shared += [
                bulb.trailingAnchor.constraint(equalTo: trailingAnchor),
                bulb.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.trailingAnchor.constraint(equalTo: bulb.leadingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
            ]
        }
        NSLayoutConstraint.activate(shared)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func setShowName(_ value: Bool, animated: Bool) {
        showName = value
        resize()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                text.animator().alphaValue = value ? 1 : 0
            }
        } else {
            text.alphaValue = value ? 1 : 0
        }
    }

    func apply(_ row: Row) {
        bulb.show(row.signal)
        titleLabel.stringValue = row.headline
        projectLabel.stringValue = row.subtitle ?? ""
        projectLabel.isHidden = row.subtitle == nil
        toolTip = "\(row.headline) — \(row.note)"
        resize()
    }

    private func resize() {
        widthConstraint.constant = fittingWidth
        heightConstraint.constant = fittingHeight
    }
}
