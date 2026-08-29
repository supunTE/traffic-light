import AppKit

/// Draws the Signal indicator.
///
/// Four of the five are SF Symbols. `Working` is not: it is an arc that turns
/// while its length breathes, because "something is happening" is the one
/// Signal a static shape cannot say. Everything else is deliberately still —
/// motion is the loudest thing an ambient widget can do, so exactly one state
/// gets it.
enum Bulb {
    /// One turn every this many seconds. Slow enough to read as *ongoing*
    /// rather than *urgent*: a fast spinner says "wait for me", which is the
    /// opposite of what Working means.
    static let rotationPeriod: CFTimeInterval = 1.9

    /// How long the arc takes to grow and shrink once. Deliberately not a
    /// whole fraction of the rotation, so the two never sync up into a
    /// pattern that reads as mechanical.
    static let breathePeriod: CFTimeInterval = 1.45

    /// Shortest and longest the arc gets, as a fraction of the circle. It
    /// never closes: a complete ring turning looks identical to one standing
    /// still, so the gap is what makes the motion legible at all.
    static let minArc: CGFloat = 0.08
    static let maxArc: CGFloat = 0.78

    /// Deliberately not proportional to the diameter. Stroke weight is read
    /// absolutely, the way a font weight is — scale it with the circle and the
    /// 22pt floating-bar ring becomes a doughnut while the 14pt menu bar one
    /// stays a hairline, and the two stop looking like the same object.
    /// Clamped so every size lands on the menu bar's weight.
    ///
    /// `resting` is Idle. It shares the ring's geometry with Working, but not
    /// its weight: identical strokes made the two read as equally present,
    /// when Idle means nothing is happening. Half the weight says dormant
    /// without needing a different shape — and it restores roughly the
    /// hairline the SF Symbol circle had before Idle became a drawn ring.
    static func lineWidth(for pointSize: CGFloat, resting: Bool = false) -> CGFloat {
        let base = min(3, max(2, (pointSize / 4.5).rounded(.toNearestOrEven)))
        return resting ? max(1.5, base / 2) : base
    }

    /// What fraction of its square an SF Symbol disc actually fills.
    ///
    /// Measured, not assumed. `circle.fill` leaves padding inside its own box,
    /// so a ring drawn to the edge of the same box comes out visibly larger
    /// than the filled circles beside it — the rings looked like they were
    /// drawn *around* the others rather than being the same object.
    static let discRatio: CGFloat = {
        let size: CGFloat = 32
        guard let disc = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        else { return 0.81 }

        let scale = 4
        let w = Int(disc.size.width) * scale, h = Int(disc.size.height) * scale
        guard w > 0, h > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return 0.81 }
        rep.size = disc.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        disc.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var minX = w, maxX = -1
        for y in 0..<h {
            for x in 0..<w where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x)
            }
        }
        guard maxX >= 0 else { return 0.81 }
        let ink = CGFloat(maxX + 1 - minX) / CGFloat(scale)
        return ink / max(disc.size.width, disc.size.height)
    }()

    /// A ring with a slash through it, drawn in one path so it strokes as a
    /// single shape and cannot end up half-tinted.
    static func crossedCirclePath(in rect: CGRect, lineWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let inset = lineWidth / 2 + 0.5
        let circle = rect.insetBy(dx: inset, dy: inset)
        path.addEllipse(in: circle)
        // 45°, inset from the rim so the ends sit inside the circle rather
        // than poking out of it.
        let r = circle.width / 2
        let d = r * 0.7071
        let c = CGPoint(x: circle.midX, y: circle.midY)
        path.move(to: CGPoint(x: c.x - d, y: c.y - d))
        path.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
        return path
    }

    /// The one place the ring's size is decided.
    ///
    /// `discRatio` puts the ring's outer edge on the filled symbols' edge, and
    /// half the stroke is then taken back inwards so the weight eats into the
    /// disc rather than growing past it. The animated arc and the still
    /// `NSImage` each used to work this out for themselves from the same three
    /// terms — which is a silent drift waiting to happen, since the failure is
    /// a ring a fraction larger than the circles beside it and nothing else.
    static func ringRadius(in rect: CGRect, lineWidth: CGFloat) -> CGFloat {
        let outer = min(rect.width, rect.height) * discRatio / 2
        return max(lineWidth / 2, outer - lineWidth / 2)
    }

    /// A full circle at `ringRadius`, so a ring and a filled circle have the
    /// same outer silhouette.
    ///
    /// The visible slice is chosen by `strokeStart`/`strokeEnd`, which is what
    /// lets the arc's length animate.
    static func ringPath(in rect: CGRect, lineWidth: CGFloat) -> CGPath {
        let radius = ringRadius(in: rect, lineWidth: lineWidth)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        return path
    }

    /// Measured once per point size: asking AppKit for a symbol is not free,
    /// and every row of every menu asks.
    private static var canvasCache: [CGFloat: CGFloat] = [:]

    /// The square an SF Symbol occupies at this point size, taken from a real
    /// symbol rather than approximated. `ceil(pointSize / 12 * 15)` was close
    /// but rounded to 23 where the symbols round to 22, which left every ring
    /// a fraction wider than the filled circles beside it in a menu.
    static func canvasSide(for pointSize: CGFloat) -> CGFloat {
        if let cached = canvasCache[pointSize] { return cached }
        let side: CGFloat
        if let disc = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold)) {
            side = ceil(max(disc.size.width, disc.size.height))
        } else {
            side = ceil(pointSize / 12 * 15)
        }
        canvasCache[pointSize] = side
        return side
    }

    /// Still version, for menus and anywhere a plain `NSImage` is wanted.
    ///
    /// A **closed** ring, not a slice of the animated arc. Nothing inside an
    /// open menu can animate — a menu item's image is a static `NSImage` — and
    /// a partial arc frozen in place does not read as "a spinner, paused". It
    /// reads as something broken or half-drawn. A complete ring says the same
    /// thing the motion says, in the one context where there is no motion.
    static func ringImage(color: NSColor, pointSize: CGFloat,
                          resting: Bool = false) -> NSImage {
        let side = canvasSide(for: pointSize)
        let width = lineWidth(for: pointSize, resting: resting)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let radius = ringRadius(in: rect, lineWidth: width)
            let path = NSBezierPath(ovalIn: NSRect(x: rect.midX - radius, y: rect.midY - radius,
                                                   width: radius * 2, height: radius * 2))
            path.lineWidth = width
            color.setStroke()
            path.stroke()
            return true
        }
    }
}

/// A Signal indicator that can animate. Layer-backed rather than a timer
/// redrawing an image: the animation runs on the render server, so it costs no
/// CPU in this process and keeps moving smoothly while the daemon is busy
/// ingesting.
final class BulbView: NSView {
    private let shape = CAShapeLayer()
    private var signal: Signal?
    private var offDuty = false
    private let pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = nil
        shape.lineCap = .round
        shape.lineWidth = Bulb.lineWidth(for: pointSize)
        shape.strokeStart = 0
        shape.strokeEnd = Bulb.minArc
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { false }

    /// Gives SwiftUI and any autolayout parent something to size against.
    /// Without it the view can be handed a frame its layer geometry never
    /// reconciles with, and the drawn ring comes out a fraction of the size
    /// of the symbols beside it.
    override var intrinsicContentSize: NSSize {
        NSSize(width: pointSize + 4, height: pointSize + 4)
    }

    /// `layout()` alone is not enough: a view placed by SwiftUI, or resized
    /// without autolayout, gets its frame changed without a layout pass.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reshape()
    }

    func show(_ signal: Signal) {
        guard signal != self.signal || offDuty else { return }
        offDuty = false
        self.signal = signal
        needsLayout = true
        reshape()
    }

    /// Off duty replaces the Signal rather than dimming it.
    ///
    /// A crossed circle, because that is what a signal out of service is
    /// marked with — and because a dimmed red still reads as a red you could
    /// act on, when in fact nothing is being reported at all. The stroke is
    /// the ordinary label colour, so it looks like part of the menu bar rather
    /// than a Signal of its own.
    func showOffDuty() {
        guard !offDuty else { return }
        offDuty = true
        signal = nil
        needsLayout = true
        reshape()
    }

    /// A sublayer added by hand keeps `contentsScale` 1.0 even on a Retina
    /// display — the view's own backing layer gets the right scale, its
    /// children do not. The stroke is then rasterised at half resolution and
    /// scaled up, which is exactly what makes a rotating ring look jagged and
    /// judder rather than glide.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        shape.contentsScale = scale
        layer?.contentsScale = scale
    }

    override func layout() {
        super.layout()
        reshape()
    }

    private func reshape() {
        if offDuty {
            let side = min(bounds.width, bounds.height)
            let square = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                                width: side, height: side)
            shape.frame = square
            shape.lineWidth = Bulb.lineWidth(for: pointSize, resting: true)
            shape.path = Bulb.crossedCirclePath(in: CGRect(origin: .zero, size: square.size),
                                                lineWidth: shape.lineWidth)
            shape.strokeStart = 0
            shape.strokeEnd = 1
            shape.removeAllAnimations()
            shape.strokeColor = NSColor.tertiaryLabelColor.cgColor
            updateScale()
            return
        }
        // The stroke weight depends on the Signal and the path's inset depends
        // on the stroke, so the two are always rebuilt together.
        shape.lineWidth = Bulb.lineWidth(for: pointSize, resting: signal == .idle)

        // Rotation happens about the layer's anchor point, its centre — so the
        // frame must be square or the arc wobbles as it turns.
        let side = min(bounds.width, bounds.height)
        let square = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                            width: side, height: side)
        shape.frame = square
        shape.path = Bulb.ringPath(in: CGRect(origin: .zero, size: square.size),
                                   lineWidth: shape.lineWidth)
        updateScale()
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// System colours resolve differently in light and dark mode, and a
    /// `CGColor` captured once does not follow — so it is re-resolved against
    /// the current appearance every time.
    private func applyAppearance() {
        guard let signal else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Working and Idle share the shape layer, so the turning arc and
            // the still circle are the same object at the same size in the
            // same place — matched by construction rather than by two
            // measurements agreeing.
            if signal == .working || signal == .idle {
                shape.isHidden = false
                shape.strokeColor = signal.color.cgColor
                layer?.contents = nil
                if signal == .working {
                    startAnimating()
                } else {
                    stopAnimating()
                    shape.strokeStart = 0
                    shape.strokeEnd = 1
                }
            } else {
                shape.isHidden = true
                stopAnimating()
                layer?.contents = signal.image(pointSize: pointSize)
                // resizeAspect, not center: the symbol's square canvas is
                // sized from the point size and need not match the view's
                // box exactly, and .center would clip rather than fit.
                layer?.contentsGravity = .resizeAspect
            }
        }
    }

    private func startAnimating() {
        guard shape.animation(forKey: "spin") == nil else { return }

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = Bulb.rotationPeriod
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        // Linear, or the rotation visibly stalls at each cycle boundary.
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        shape.add(spin, forKey: "spin")

        // Autoreversing rather than a head-and-tail pair: it cannot develop a
        // seam where the cycle restarts, which is the usual way a hand-rolled
        // spinner ends up looking like it stutters once a second.
        let breathe = CABasicAnimation(keyPath: "strokeEnd")
        breathe.fromValue = Bulb.minArc
        breathe.toValue = Bulb.maxArc
        breathe.duration = Bulb.breathePeriod
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.isRemovedOnCompletion = false
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shape.add(breathe, forKey: "breathe")
    }

    private func stopAnimating() {
        shape.removeAnimation(forKey: "spin")
        shape.removeAnimation(forKey: "breathe")
    }
}
