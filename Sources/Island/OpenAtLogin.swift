import AppKit
import ServiceManagement

/// Glance opens at login by default. On the first launch (of a build with this code) Glance
/// registers itself as a login item, unless the user has ever switched "Open at login" off
/// from Glance's Settings or menu. It does this once only, so turning it off in System
/// Settings › General › Login Items is respected too.
@MainActor
enum OpenAtLogin {
    private static let userChoiceKey = "OpenAtLoginUserChoice"     // Bool, set by the toggles
    private static let autoDoneKey = "OpenAtLoginAutoRegistered"   // Bool, the one-time default ran

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Called once at launch (not in isolated test instances).
    static func applyDefault() {
        let d = Env.defaults
        guard !AppIdentity.isTestBuild else { return } // MARK: wip/character
        guard d.object(forKey: userChoiceKey) == nil, !d.bool(forKey: autoDoneKey) else { return }
        d.set(true, forKey: autoDoneKey)
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            NSLog("Glance: registered to open at login (default), status \(SMAppService.mainApp.status.rawValue)")
        } catch {
            NSLog("Glance: open-at-login default failed: \(error)")
        }
    }

    /// Settings / menu toggle. Remembers that the user chose, so the default never overrides it.
    @discardableResult
    static func set(_ on: Bool) throws -> SMAppService.Status {
        Env.defaults.set(on, forKey: userChoiceKey)
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        return SMAppService.mainApp.status
    }
}
