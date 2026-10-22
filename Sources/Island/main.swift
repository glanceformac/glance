import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var island: IslandWindowController?
    private let settingsWindow = SettingsWindowController()
    private let dials = DialsWindowController()
    private let statusMenu = StatusMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--character-selftest") { CharacterSelfTest.run() } // MARK: wip/character
        Env.checkIsolation()   // isolated test mode: private data folder, defaults and pasteboard (logged)
        // Cinema intro/outro: sample the keyframes and draw the text once, so the first play is smooth.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            IntroH.prewarm(pill: IslandModel.shared.closedSize, touchBar: TouchBarAPI.available ? CGSize(width: 1000, height: 28) : nil)
        }
        AppDelegate.shared = self
        island = IslandWindowController()
        SystemMedia.shared.start() // MARK: feat/system-media (also in isolated test instances)
        if Env.isolated {
            // Test instance: only the Claude/Chrome socket + Cinema logic; nothing persisted.
            // Hidden unless GLANCE_TEST_VISIBLE=1 (used for performance experiments).
            if ProcessInfo.processInfo.environment["GLANCE_TEST_VISIBLE"] != "1" { island?.setHidden(true) }
            ClaudeServer.shared.start()
            GitWatch.shared.start()   // MARK: wip/cinema-h (only GLANCE_GIT_ROOTS scratch folders)
            DebugChannel.install()
            DevFeatures.start() // MARK: feat/claude-dev
            AppSettings.shared.onChange = { old, new in DevFeatures.prefsChanged(old.dev, new.dev) }
            ControlsFeature.start() // MARK: feat/controls (chains onto onChange, so it goes last)
            // Test instances: clipboard + Shelf on their private pasteboard and data folder,
            // and the updater only when GLANCE_UPDATE_FEED points it at a test feed.
            if ProcessInfo.processInfo.environment["GLANCE_TEST_CLIPBOARD"] == "1" { ClipboardStore.shared.updateRunning() }
            if ProcessInfo.processInfo.environment["GLANCE_TEST_VISIBLE"] == "1" { CharacterEngine.shared.start() }
            Updater.shared.start()
            return
        }

        VolumeControl.shared.start()
        BatteryMonitor.shared.start()
        AppLaunchMonitor.shared.start()
        FocusMonitor.shared.start()
        NowPlaying.shared.start()
        Weather.shared.start()
        CalendarService.shared.start()
        ClipboardStore.shared.updateRunning()
        ClipboardHotKey.update()
        _ = ShelfStore.shared
        FocusTimer.shared.reset()
        if AppSettings.shared.prefs.claudeIntegration { ClaudeServer.shared.start() }
        dials.update()
        Power.shared.start()
        IslandContext.shared.start()
        Look.shared.start()
        IslandBarHelper.update()
        OpenAtLogin.applyDefault()
        FootballService.shared.start()
        GitHubActivity.shared.start()
        GitWatch.shared.start()   // MARK: wip/cinema-h
        TodoStore.shared.scheduleTimers()
        BreakReminder.shared.apply(minutes: ToolsPrefs.shared.data.breakReminderMinutes)   // MARK: feat/productivity
        Updater.shared.start()   // Sparkle: daily check (can be switched off in Settings); before the menu is built
        statusMenu.update()
        DevFeatures.start() // MARK: feat/claude-dev
        CharacterEngine.shared.start() // MARK: wip/character
        if AppSettings.shared.prefs.islandHidden { island?.setHidden(true) }
        DebugChannel.install()
        installSignalHandlers()

        AppSettings.shared.onChange = { [weak self] old, new in
            guard let self else { return }
            if old.desktopDials != new.desktopDials { self.dials.update() }
            if old.tempUnit != new.tempUnit || old.useCurrentLocation != new.useCurrentLocation { Weather.shared.refreshLocation() }
            if old.nowPlaying != new.nowPlaying { new.nowPlaying ? NowPlaying.shared.start() : NowPlaying.shared.stop() }
            if old.lyrics != new.lyrics { Lyrics.shared.trackChanged() }
            if old.timerMinutes != new.timerMinutes, !FocusTimer.shared.running { FocusTimer.shared.reset() }
            if old.claudeIntegration != new.claudeIntegration {
                new.claudeIntegration ? ClaudeServer.shared.start() : ClaudeServer.shared.stop()
            }
            if old.theme != new.theme { self.dials.refreshTheme() }
            if old.footballMode != new.footballMode || old.footballTeam != new.footballTeam {
                new.footballMode ? FootballService.shared.teamChanged() : FootballService.shared.stop()
            }
            if old.githubActivity != new.githubActivity {
                new.githubActivity ? GitHubActivity.shared.start() : GitHubActivity.shared.stop()
            }
            if old.gitWatchFolders != new.gitWatchFolders {
                new.gitWatchFolders ? GitWatch.shared.start() : GitWatch.shared.stop()   // MARK: wip/cinema-h
            }
            if old.endOfDayHour != new.endOfDayHour { TodoStore.shared.scheduleTimers() }
            if old.batterySaverAuto != new.batterySaverAuto { Power.shared.refresh() }
            if old.touchBarButton != new.touchBarButton { IslandBarHelper.update() }
            if old.cinemaExtension != new.cinemaExtension { ChromeAmbilight.shared.toggled(on: new.cinemaExtension) }
            if old.touchBarGlow != new.touchBarGlow, !new.touchBarGlow { TouchBarGlow.shared.end() }
            if old.islandHidden != new.islandHidden { self.island?.setHidden(new.islandHidden) }
            if old.showMenuBarIcon != new.showMenuBarIcon { self.statusMenu.update() }
            if old.accent != new.accent { Look.shared.refreshWallpaperIfNeeded() }
            if old.clipboardPaused != new.clipboardPaused || old.clipboardIgnoredApps.isEmpty != new.clipboardIgnoredApps.isEmpty { ClipboardStore.shared.updateRunning() }
            if old.clipboardHotkey != new.clipboardHotkey { ClipboardHotKey.update() }
            if old.dev != new.dev { DevFeatures.prefsChanged(old.dev, new.dev) } // MARK: feat/claude-dev
        }
        ControlsFeature.start() // MARK: feat/controls (chains onto onChange above)

        // Debug/testing hook: `open Glance.app --args --expanded` or `--peek`.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--expanded") { IslandModel.shared.setExpanded(true); IslandModel.shared.editing = args.contains("--edit") }
        showSettingsOnLaunchIfWanted() // MARK: wip/character
        if args.contains("--peek") {
            IslandModel.shared.enqueue(Peek(symbol: "bolt.fill", title: "Charging", subtitle: "82%", tint: .green, duration: 30))
        }
    }

    private var sigSources: [DispatchSourceSignal] = []

    /// Clean shutdown (removes the socket) on SIGTERM/SIGINT too.
    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            sigSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClaudeServer.shared.stop()
        NowPlaying.shared.stop()
        ClipboardStore.shared.persistNow()
        DevFeatures.terminate() // MARK: feat/claude-dev
    }

    func showSettings(page: SettingsPage? = nil) { settingsWindow.show(page: page) }

    // MARK: wip/character: opening Glance shows Settings, like a normal app.

    /// Launched by the login item (or at boot): stay quiet in the menu bar.
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == kAEOpenApplication,
           e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAsLoginItem = true
        }
    }

    /// Settings on a launch by hand, and always on the first launch of a new install or version.
    private func showSettingsOnLaunchIfWanted() {
        let key = "SettingsShownForBuild"
        let stamp = "\(Bundle.main.bundlePath)|\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")"
        let firstOfThisBuild = Env.defaults.string(forKey: key) != stamp
        let byHand = !launchedAsLoginItem && ProcessInfo.processInfo.systemUptime > 180
            && !ProcessInfo.processInfo.arguments.contains("--no-settings")
        guard firstOfThisBuild || byHand else { return }
        Env.defaults.set(stamp, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showSettings() }
    }

    /// Quit chosen by the user (menu bar, Settings, command palette). Unlike a system restart
    /// or an update, it also forgets Keep awake so it does not switch itself on again next time.
    static func quitByUser() {
        KeepAwake.shared.forgetResume()
        NSApp.terminate(nil)
    }

    /// `open glance://play-goal` plays the goal celebration (last real goal, or the demo).
    /// That is the only thing the URL scheme can do.
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "glance" {
            if u.host == "play-goal" { FootballService.shared.playLastGoal() }
            if u.host == "cinema-status" { ChromeAmbilight.shared.writeStatus() } // diagnostics file only
            if u.host == "toggle" { AppSettings.shared.prefs.islandHidden.toggle() }  // Control Strip button
        }
    }

    /// Opening Glance.app again (Finder, Spotlight, Launchpad) brings back the menu bar
    /// icon and the island if either was hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        var p = AppSettings.shared.prefs
        p.showMenuBarIcon = true
        p.islandHidden = false
        AppSettings.shared.prefs = p
        showSettings() // MARK: wip/character: and opens Settings, like any app
        return false
    }
}

extension DialsWindowController {
    func refreshTheme() {
        // Views read Theme.current, which is observable; nothing else needed.
    }
}

MainActor.assumeIsolated {
    LegacyMigration.run()   // before anything reads settings or Application Support
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
