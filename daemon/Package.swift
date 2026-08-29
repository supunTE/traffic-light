// swift-tools-version: 6.0
import PackageDescription

// A plain SwiftPM executable, with no GUI framework beneath it: setting
// NSApplication's activation policy to .accessory is enough to own a status
// item and a floating panel, and nothing here needs notarization to run.
//
// `install.sh` wraps this binary in an .app bundle afterwards. That is for the
// icon, the version in About, and the Login Item registration — none of which
// SwiftPM produces, and none of which the code depends on.
let package = Package(
    name: "TrafficLight",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "traffic-light",
            path: "Sources/TrafficLight",
            swiftSettings: [
                // AppKit's singletons are main-thread-bound in ways Swift 6's
                // strict concurrency cannot yet express without heavy
                // annotation. Revisit once the renderers have settled.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
