import Foundation

func printStatus() {
    let rows = Store.rows(from: Store.loadSnapshot())
    let reporting = rows.filter(\.reporting)
    let aggregate = Signal.aggregate(reporting.map(\.signal))

    print("")
    print(TerminalRow.header(aggregate, count: reporting.count))
    print("")
    for row in reporting { print(TerminalRow.line(row)) }
    if reporting.isEmpty { print("  \(dim)\(Wording.nothingConnected)\(reset)") }
    let silent = rows.filter { !$0.reporting }
    if !silent.isEmpty {
        print("  \(dim)\(Wording.othersNotConnected(silent.count)): "
              + "\(silent.map(\.name).joined(separator: ", "))\(reset)")
    }
    print("")
}

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

/// The Distress Call: the one route to Broken that carries a human-readable
/// reason. Writes an event the daemon picks up like any other, so it needs no
/// privileged channel and works even if the daemon is down.
func distress(_ reason: String) {
    guard let session = SelfIdentity.currentSession() else {
        FileHandle.standardError.write(Data(
            "traffic-light: not running inside a Claude Code session — nothing to mark Broken\n".utf8))
        exit(1)
    }

    let now = Date().timeIntervalSince1970
    // Built with no Optionals in it: JSONSerialization rejects a wrapped
    // Optional outright, and it fails by returning nil rather than by
    // complaining — which looks exactly like success from the caller's side.
    var payload: [String: String] = [
        "hook_event_name": "DistressCall",
        "session_id": session.sessionId,
        "reason": reason
    ]
    if let cwd = session.cwd { payload["cwd"] = cwd }

    guard let data = try? JSONSerialization.data(withJSONObject: ["at": now, "payload": payload])
    else {
        FileHandle.standardError.write(Data("traffic-light: could not encode the distress call\n".utf8))
        exit(1)
    }
    try? FileManager.default.createDirectory(at: Paths.inbox, withIntermediateDirectories: true)
    do {
        try data.write(to: Paths.inbox.appending(path: "\(Int(now))-distress-\(getpid()).json"))
    } catch {
        FileHandle.standardError.write(Data("traffic-light: could not write to the inbox: \(error)\n".utf8))
        exit(1)
    }
    print("traffic-light: \(session.name ?? session.sessionId) is now Broken — \(reason)")
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "status", nil:
    // Double-clicking the app, or launching it from Spotlight, runs this with
    // no arguments — and a status line printed to a stdout nobody is reading
    // is not what that click meant. In a bundle, no arguments means "run".
    if args.isEmpty, Bundle.main.bundleURL.pathExtension == "app" {
        Daemon.run(headless: false)
    } else {
        printStatus()
    }

case "doctor":
    Doctor.run()

case "preview":
    // Settings is the place to change any of this; `preview` shows the whole
    // vocabulary at once — every Signal with its wording and its chime — which
    // a window showing one project's state cannot.
    Preview.run()

case "settings":
    // Not in --help, same as `icon`: this exists so the window can be worked
    // on without the daemon running, and a command nobody needs is still a
    // command everybody has to read past.
    MainActor.assumeIsolated {
        if args.count > 2, args[1] == "--render" {
            SettingsShots.write(to: args[2])
        } else if args.count > 2, args[1] == "--shots" {
            // The real thing, controls included. `--render` is the SwiftUI-only
            // fallback and draws every AppKit control as an empty box.
            SettingsShots.writeWindowShots(to: args[2])
        } else {
            Settings.runStandalone()
        }
    }

case "icon":
    // Not in --help: this exists to regenerate the file in the README, which
    // happens about once, and a command nobody needs is still a command
    // everybody has to read past.
    let size = args.count > 2 ? Double(args[2]) ?? 512 : 512
    guard args.count > 1, let data = AppIcon.png(size: size) else {
        FileHandle.standardError.write(Data("usage: traffic-light icon <path.png> [size]\n".utf8))
        exit(2)
    }
    do {
        try data.write(to: URL(fileURLWithPath: args[1]))
        print("wrote \(args[1]) at \(Int(size))px")
    } catch {
        FileHandle.standardError.write(Data("traffic-light: \(error)\n".utf8))
        exit(1)
    }

case "login-item":
    // Not in --help: the installer calls this, and it is the installer's job.
    switch args.count > 1 ? args[1] : "status" {
    case "register": exit(LoginItem.register())
    case "unregister": LoginItem.unregister()
    default: exit(LoginItem.status())
    }

case "broken":
    guard args.count > 1 else {
        FileHandle.standardError.write(Data("usage: traffic-light broken \"<reason>\"\n".utf8))
        exit(2)
    }
    distress(args[1])

case "cleanup":
    Cleanup.run(logs: args.contains("--logs"))

case "daemon":
    Daemon.run(headless: args.contains("--headless") || args.contains("--once"),
               once: args.contains("--once"))

case "-h", "--help", "help":
    print("""
    traffic-light — ambient status for Claude Code

      status                 print every live session and its Signal
      doctor                 check the install and say what to fix
      daemon                 watch the inbox and render (menu bar + floating bar)
      daemon --headless      same, but terminal output only
      daemon --once          drain the inbox, render one frame, exit
      preview                every Signal, its wording and its chime
      broken "<reason>"      Distress Call: mark this session Broken
      cleanup                drop finished sessions now, without waiting an hour
      cleanup --logs         also delete the event log

    State lives in ~/Library/Application Support/traffic-light/
    """)

default:
    FileHandle.standardError.write(Data("unknown command: \(args[0])\n".utf8))
    exit(2)
}
