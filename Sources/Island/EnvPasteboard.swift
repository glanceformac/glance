import AppKit

extension Env {
    /// The general pasteboard, or a private named one in isolated test mode, so a test
    /// instance never reads your real clipboard or writes to it.
    nonisolated(unsafe) static let pasteboard: NSPasteboard = {
        if dataRoot != nil { return NSPasteboard(name: NSPasteboard.Name("app.glanceformac.glance.test." + tag)) }
        return .general
    }()
}
