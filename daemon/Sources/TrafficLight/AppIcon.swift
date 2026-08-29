import AppKit

/// The app mark: three lamps in a housing, on a dark rounded square.
///
/// Drawn rather than shipped as a file, so every size is the same artwork
/// rather than a set of exports that can drift apart. The files that do exist
/// are all produced from this one: `traffic-light icon` renders the bundle's
/// `AppIcon.icns` at install time, and `assets/icon.png` for the README and
/// the npm page. This drawing stays the single definition of the mark.
///
/// Red, amber and green are exactly the Broken, Asking and Done Signals, so
/// the icon is the palette rather than a picture of one. Working's purple and
/// Idle's white are left out: a junction has no lamp for either, and three
/// lamps is what makes the shape read as a traffic light at all.
enum AppIcon {
    // Fixed sRGB rather than system colours. Everything else here adapts to
    // light and dark on purpose; an icon must not. It gets composited onto a
    // Dock, a Finder list and a GitHub page, and it should be the same mark
    // in all of them.
    private static let backdrop = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.102, alpha: 1)
    private static let red = NSColor(srgbRed: 1.00, green: 0.271, blue: 0.227, alpha: 1)
    private static let amber = NSColor(srgbRed: 1.00, green: 0.624, blue: 0.039, alpha: 1)
    private static let green = NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)

    /// Drawn on a 100×100 grid and scaled, so every size is the same artwork
    /// rather than a set of hand-tuned variants that disagree with each other.
    /// Cached per size. Drawing it is only 0.3 ms, but it is drawn from the
    /// sidebar's body, which SwiftUI re-evaluates freely — and a cost paid on
    /// every invalidation is a cost paid during a scroll.
    private static var cache: [CGFloat: NSImage] = [:]

    static func image(size: CGFloat = 512) -> NSImage {
        if let hit = cache[size] { return hit }
        let drawn = draw(size: size)
        cache[size] = drawn
        return drawn
    }

    private static func draw(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let k = size / 100

            backdrop.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 22 * k, yRadius: 22 * k).fill()

            // The housing is what makes this a traffic light rather than three
            // dots in a column. It is also the first thing to go illegible as
            // the icon shrinks — the trade accepted in choosing this design.
            let housing = NSBezierPath(
                roundedRect: NSRect(x: 32 * k, y: 8 * k, width: 36 * k, height: 84 * k),
                xRadius: 18 * k, yRadius: 18 * k)
            housing.lineWidth = 4 * k
            NSColor(white: 1, alpha: 0.16).setStroke()
            housing.stroke()

            for (centre, colour) in [(26.0, red), (50.0, amber), (74.0, green)] {
                colour.setFill()
                let r = 10 * k
                NSBezierPath(ovalIn: NSRect(x: 50 * k - r, y: CGFloat(centre) * k - r,
                                            width: r * 2, height: r * 2)).fill()
            }
            return true
        }
    }

    /// PNG at a given edge length, for anywhere a real file is needed.
    static func png(size: CGFloat) -> Data? {
        let icon = image(size: size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = icon.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
