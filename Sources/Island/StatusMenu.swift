import AppKit
import ServiceManagement

/// Menu bar icon: Show/Hide Glance, Settings…, Launch at login, Quit.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let showHide = NSMenuItem(title: "Hide Glance", action: #selector(toggleIsland), keyEquivalent: "")
    private let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func update() {
        let want = AppSettings.shared.prefs.showMenuBarIcon
        if want, item == nil { create() }
        if !want, let i = item { NSStatusBar.system.removeStatusItem(i); item = nil }
    }

    private func create() {
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Glance") {
            img.isTemplate = true
            i.button?.image = img
        }
        i.button?.toolTip = "Glance"
        let menu = NSMenu()
        menu.delegate = self
        for m in [showHide, login] { m.target = self }
        menu.addItem(showHide)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(login)
        if Updater.shared.available {
            let upd = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            upd.target = self
            menu.addItem(upd)
        }
        menu.addItem(.separator())
        let goal = NSMenuItem(title: "Play Goal Celebration", action: #selector(playGoal), keyEquivalent: "")
        goal.target = self
        menu.addItem(goal)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Glance", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        i.menu = menu
        item = i
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            showHide.title = AppSettings.shared.prefs.islandHidden ? "Show Glance" : "Hide Glance"
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func toggleIsland() { AppSettings.shared.prefs.islandHidden.toggle() }
    @objc private func openSettings() { AppDelegate.shared?.showSettings() }
    @objc private func quit() { AppDelegate.quitByUser() }
    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }
    @objc private func playGoal() { FootballService.shared.playLastGoal() }
    @objc private func toggleLogin() {
        do {
            try OpenAtLogin.set(SMAppService.mainApp.status != .enabled)
        } catch {
            NSLog("Glance: login item change failed: \(error)")
        }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
