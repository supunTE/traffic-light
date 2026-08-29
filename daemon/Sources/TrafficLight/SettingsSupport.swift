import AppKit
import CoreImage

/// What the phone does when a notification lands.
///
/// Named rather than numbered. ntfy's wire values are 1–5, and a setting whose
/// meaning lives in someone else's documentation is not a setting — you would
/// be choosing a number and hoping.
enum PushPriority: String, CaseIterable {
    case min, low, `default`, high, urgent

    var label: String {
        switch self {
        case .min: "Silent"
        case .low: "Low"
        case .default: "Normal"
        case .high: "High"
        case .urgent: "Urgent"
        }
    }

    /// One step below where this started, across the board. Urgent bypasses
    /// the phone's own quiet hours, which is more than a blocked session has
    /// earned — and the ranking lives in the gaps between the levels, not in
    /// how loudly the top one shouts.
    static func `default`(for signal: Signal) -> PushPriority {
        switch signal {
        case .broken: .high
        case .asking: .default
        default: .low
        }
    }
}

extension Bell {
    /// Auditioning and the real chime go through one function, so a sound that
    /// plays in Settings is a sound that will play in anger.
    static func play(_ name: String, volume: Double) {
        guard let sound = NSSound(named: name) else { return }
        sound.volume = Float(max(0, min(1, volume)))
        sound.play()
    }
}

/// Namespace for the chime, so `Bell.play` has somewhere to live without
/// belonging to the renderer that happens to ring it.
enum Bell {}

extension Push {
    /// A real push through the real path, because "is push working" is
    /// otherwise a question you can only answer by needing it and finding out
    /// that it wasn't.
    static func test(config: Config, done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(config.push.server)/\(config.push.topic)") else {
            done(false); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("Traffic Light test push".utf8)
        request.setValue("Traffic Light", forHTTPHeaderField: "Title")
        request.setValue("bell", forHTTPHeaderField: "Tags")
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { _, response, error in
            let ok = error == nil && ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }
}

enum Push {}

/// A QR of the `ntfy://` subscribe link.
///
/// Built with CoreImage rather than a dependency — this is one filter that has
/// shipped with macOS for a decade, and a package would be a supply chain for
/// a square of black dots.
enum QR {
    /// Measured at 3.8 ms to build. A SwiftUI body is re-evaluated whenever
    /// anything in the view invalidates, and 3.8 ms against an 8.3 ms frame is
    /// most of the budget — so it is built once per string and kept. The key
    /// is the content, so rotating the topic still redraws.
    private static var cache: [String: NSImage] = [:]

    static func image(for string: String, side: CGFloat) -> NSImage? {
        let key = "\(string)@\(side)"
        if let hit = cache[key] { return hit }
        guard let image = build(string, side: side) else { return nil }
        cache[key] = image
        return image
    }

    private static func build(_ string: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        // M: recovers from ~15% damage. H would be more robust and denser, and
        // density is what makes a code fail to scan on a screen.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

extension FloatingBarRenderer {
    /// The bar is draggable, so it can end up under the notch, or on
    /// a monitor that has since been unplugged, with no way back.
    static func resetPosition() {
        NotificationCenter.default.post(name: .trafficLightResetBar, object: nil)
    }
}

extension Notification.Name {
    static let trafficLightResetBar = Notification.Name("traffic-light.reset-bar")
}

/// One entry in a snooze submenu. A class, because `representedObject` is
/// `Any?` and a struct would be boxed on every menu rebuild.
final class SnoozeChoice: NSObject {
    let level: Attention
    let title: String
    /// Evaluated when chosen, not when the menu is built — the menu is rebuilt
    /// each time it opens, and "4 hours from when the menu was drawn" is not
    /// what anybody means.
    let until: () -> Date?

    init(level: Attention, title: String, until: @escaping () -> Date?) {
        self.level = level
        self.title = title
        self.until = until
    }

    static func all(level: Attention) -> [SnoozeChoice] {
        [
            SnoozeChoice(level: level, title: "1 hour") { Date().addingTimeInterval(3600) },
            SnoozeChoice(level: level, title: "2 hours") { Date().addingTimeInterval(7200) },
            SnoozeChoice(level: level, title: "4 hours") { Date().addingTimeInterval(14400) },
            SnoozeChoice(level: level, title: "The rest of today") {
                let calendar = Calendar.current
                let midnight = calendar.startOfDay(for: Date().addingTimeInterval(86400))
                return midnight
            },
            // The only form that cannot expire on its own, which is exactly
            // why the dimmed bulb and the crossed circle exist.
            SnoozeChoice(level: level, title: "Until I turn it back on") { nil }
        ]
    }
}
