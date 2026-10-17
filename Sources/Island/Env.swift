import Foundation

/// Test-launch switches.
enum Env {
    /// `GLANCE_NO_PERMISSIONS=1` or `--no-permissions`: never trigger Calendar, Location,
    /// Automation (AppleScript) or Accessibility requests; show demo data instead.
    /// Every development/test launch uses this so you are never re-prompted.
    /// Isolated test instance: private socket path, hidden panel, no persistence side effects.
    /// Lets a test Chrome profile talk to a test Glance without touching the real one.
    static let testSocket: String? = ProcessInfo.processInfo.environment["GLANCE_SOCKET_PATH"]
    static var isolated: Bool { testSocket != nil }

    static let noPermissions: Bool = ProcessInfo.processInfo.environment["GLANCE_NO_PERMISSIONS"] == "1"
        || ProcessInfo.processInfo.arguments.contains("--no-permissions")

    // MARK: Isolated data (every store, cache, setting and the pasteboard)

    /// Test instance tag (also selects the private debug channel).
    static let tag: String = {
        let t = ProcessInfo.processInfo.environment["GLANCE_DEBUG_TAG"] ?? ""
        return t.isEmpty ? "test" : t
    }()

    /// Isolated mode: a private root next to the test socket, e.g. <scratch>/glance-data-<tag>.
    /// Nothing under ~/Library is read or written for data in that mode.
    static let dataRoot: URL? = testSocket.map {
        URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("glance-data-" + tag, isDirectory: true)
    }

    /// Glance's Application Support folder (clipboard, shelf, notes, prompter scripts, tools...).
    static var supportDir: URL {
        if let r = dataRoot { return r.appendingPathComponent("Application Support/Glance", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Glance", isDirectory: true)
    }

    /// Base caches folder (callers append "Glance/..."), private in isolated mode.
    static var cachesBase: URL {
        if let r = dataRoot { return r.appendingPathComponent("Caches", isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// Settings storage: a separate defaults domain in isolated mode (never the real prefs).
    nonisolated(unsafe) static let defaults: UserDefaults = {
        if dataRoot != nil, let d = UserDefaults(suiteName: "app.glanceformac.glance.test." + tag) { return d }
        return .standard
    }()

    /// Startup check for isolated mode: logs the data folder and refuses to run if it would be the real one.
    static func checkIsolation() {
        guard let r = dataRoot else { return }
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        precondition(!supportDir.path.hasPrefix(real) && !cachesBase.path.hasPrefix(real), "isolated data must not live in ~/Library")
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSLog("Glance ISOLATED test mode: data in %@ (defaults suite app.glanceformac.glance.test.%@, private pasteboard)", r.path, tag)
    }
}

import AppKit

/// The menu bar screen's frames, without crashing when macOS briefly reports no screen at all
/// (lid closed with an external display unplugged, sleep and wake reconfiguration).
struct SafeScreen {
    let frame: NSRect
    let visibleFrame: NSRect
    /// False while there is no screen; callers that place windows should wait for the next change.
    let isReal: Bool

    @MainActor static var primary: SafeScreen {
        if let s = NSScreen.screens.first ?? NSScreen.main { return SafeScreen(frame: s.frame, visibleFrame: s.visibleFrame, isReal: true) }
        let f = NSRect(x: 0, y: 0, width: 1440, height: 900)
        return SafeScreen(frame: f, visibleFrame: f, isReal: false)
    }
}
