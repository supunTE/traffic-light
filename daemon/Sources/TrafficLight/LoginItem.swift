import Foundation
import ServiceManagement

/// Starting at login, registered by the app rather than by dropping a file in
/// `~/Library/LaunchAgents`.
///
/// The difference is what System Settings shows you. A loose plist is
/// attributed to the program it points at, so the row reads `traffic-light`
/// with a generic executable icon — the same treatment a stray shell script
/// gets. A plist *inside* the bundle, registered through `SMAppService`, is
/// attributed to the bundle: the row carries the app's name and its icon.
///
/// It stays a LaunchAgent rather than becoming `SMAppService.mainApp` because
/// the agent keeps `KeepAlive`. Losing that would trade a nice row for a light
/// that stays dead after a crash, which is the wrong way round.
enum LoginItem {
    static let plistName = "dev.supunte.traffic-light.plist"

    private static var service: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    /// Registers, and says plainly what happened. `install.sh` reads the exit
    /// code: a failure there means falling back to the loose plist rather than
    /// leaving the user with no light at login.
    static func register() -> Int32 {
        // A previous install's loose plist would run a second copy, so it goes
        // first — two daemons means two status items and two of every chime.
        removeLegacyAgent()
        do {
            if service.status == .enabled { return 0 }
            try service.register()
            print("login item registered: \(describe(service.status))")
            return 0
        } catch {
            FileHandle.standardError.write(Data(
                "login item registration failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func unregister() {
        try? service.unregister()
        removeLegacyAgent()
    }

    static func status() -> Int32 {
        print(describe(service.status))
        return service.status == .enabled ? 0 : 1
    }

    /// `~/Library/LaunchAgents/dev.supunte.traffic-light.plist` — how every
    /// install before this one started the daemon.
    private static func removeLegacyAgent() {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(plistName)")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let boot = Process()
        boot.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        boot.arguments = ["bootout", "gui/\(getuid())/dev.supunte.traffic-light"]
        try? boot.run()
        boot.waitUntilExit()
        try? FileManager.default.removeItem(at: legacy)
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "waiting for approval in Login Items"
        case .notRegistered: "not registered"
        case .notFound: "not found — is the plist inside the bundle?"
        @unknown default: "unknown"
        }
    }
}
