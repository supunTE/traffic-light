import AppKit
import SwiftUI

/// Every colour the Settings window uses, in one place.
///
/// The window used to take whatever the system handed it — `windowBackground`,
/// `controlBackground`, the user's accent — which is correct for a System
/// Settings clone and characterless for an app with a name. This is a
/// deliberate palette instead: a warm off-white ground, white cards floating on
/// it, and one accent doing selection, switches and tinted buttons so the eye
/// learns a single colour means "you can act on this".
///
/// **On the accent being green.** Green is already spoken for here — `Done` is
/// `systemGreen`, and a chrome that shouts the same colour as a Signal would
/// teach the wrong thing. So the accent is deliberately a *deeper, greyer*
/// green than any bulb: at 45 % lightness against `systemGreen`'s 72 %, it
/// reads as ink rather than as a light. The dots stay the brightest greens in
/// the window, which is the only rule that matters.
enum Palette {
    /// Selection, switches, tinted buttons, the filled day.
    static let accent = dynamic(light: hex(0x14806A), dark: hex(0x4CBF9E))
    /// The same accent as a background wash — a tinted button, a selected row.
    static let accentSoft = dynamic(light: hex(0xDCEBE4), dark: hex(0x1E3A33))
    /// Behind the pages. Never pure white, so a white card has something to sit
    /// on; never grey either, or the card looks like a patch rather than a
    /// surface.
    static let window = dynamic(light: hex(0xF5F7F6), dark: hex(0x1B1E1D))
    /// The source list, a shade further from the content than the ground is.
    static let sidebar = dynamic(light: hex(0xEBF0EC), dark: hex(0x202423))
    /// A card.
    static let card = dynamic(light: hex(0xFFFFFF), dark: hex(0x2A2E2D))
    /// A text field or anything else you type into, which has to read as
    /// recessed against the card it sits on rather than level with it.
    static let field = dynamic(light: hex(0xF2F4F3), dark: hex(0x1F2322))
    /// Dividers, and the hairline round a field. Faint on purpose: with cards
    /// this well separated from the ground, a strong rule is one line too many.
    static let hairline = dynamic(light: hex(0xE3E7E5), dark: hex(0x3A403E))

    // MARK: plumbing

    /// Resolved per appearance rather than read once, so the window follows the
    /// system into dark mode while it is open instead of at the next launch.
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                alpha: 1)
    }
}
