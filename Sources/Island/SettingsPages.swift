import AppKit
import SwiftUI

// MARK: wip/character: Settings sidebar, app identity, the small app menu, and the pages that
// did not have a home before (Calendar, About).

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, island, character, music, cinema, shelf, clipboard, calendar, tools, weather, prompter, claude, football, touchbar, updates, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .island: "Island and Notch"
        case .character: "Character"
        case .music: "Music and Lyrics"
        case .cinema: "Cinema"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .calendar: "Calendar"
        case .tools: "Tools"
        case .weather: "Weather"
        case .prompter: "Teleprompter"
        case .claude: "Claude Code"
        case .football: "Football and Celebrations"
        case .touchbar: "Touch Bar"
        case .updates: "Updates"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .island: "capsule.portrait"
        case .character: "face.smiling"
        case .music: "music.note"
        case .cinema: "film"
        case .shelf: "tray.full"
        case .clipboard: "doc.on.clipboard"
        case .calendar: "calendar"
        case .tools: "wrench.and.screwdriver"
        case .weather: "cloud.sun"
        case .prompter: "text.alignleft"
        case .claude: "sparkle"
        case .football: "soccerball"
        case .touchbar: "rectangle.and.hand.point.up.left"
        case .updates: "arrow.down.circle"
        case .about: "info.circle"
        }
    }

    @MainActor static var initial: SettingsPage = .general
    static let showNotification = Notification.Name("GlanceShowSettingsPage")
}

/// The app's display name ("Glance", or "Glance Dev" for a local test build).
enum AppIdentity {
    /// A local test build (Info.plist GlanceTestBuild = true): it never registers login items or
    /// the Touch Bar helper, so the installed Glance keeps them.
    static var isTestBuild: Bool { Bundle.main.object(forInfoDictionaryKey: "GlanceTestBuild") as? Bool == true }

    static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Glance"
    }
}

/// While Settings is open Glance is a regular app (Dock icon, menu bar with Edit so copy and
/// paste work in text fields). Otherwise it stays a menu bar app.
@MainActor
enum AppMenu {
    private final class Target: NSObject {
        @objc func settings() { MainActor.assumeIsolated { AppDelegate.shared?.showSettings() } }
        @objc func quit() { MainActor.assumeIsolated { AppDelegate.quitByUser() } }
        @objc func about() { MainActor.assumeIsolated { AppDelegate.shared?.showSettings(page: .about) } }
    }
    private static let target = Target()

    static func becomeRegular() {
        if NSApp.mainMenu == nil || NSApp.mainMenu?.items.isEmpty == true { NSApp.mainMenu = build() }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    static func becomeAccessory() {
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }

    private static func build() -> NSMenu {
        let name = AppIdentity.name
        let main = NSMenu()
        let app = NSMenu(title: name)
        app.addItem(item("About \(name)", #selector(Target.about), ""))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(Target.settings), ","))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(.separator())
        app.addItem(item("Quit \(name)", #selector(Target.quit), "q"))
        add(app, to: main)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        add(edit, to: main)
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        add(window, to: main)
        return main
    }

    private static func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = target
        return i
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let top = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        top.submenu = menu
        main.addItem(top)
    }
}

// MARK: - Calendar page

struct CalendarSettingsSection: View {
    @Bindable private var settings = AppSettings.shared
    private let calendar = CalendarService.shared

    var body: some View {
        Section("Calendar") {
            if calendar.accessDenied {
                Text("Glance can't read your calendars. Allow it in System Settings › Privacy & Security › Calendars.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Privacy & Security…") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(u) }
                }
            } else {
                LabeledContent("Next event", value: [calendar.nextTitle, calendar.nextTime].compactMap { $0 }.joined(separator: " · ").ifEmpty("Nothing coming up"))
            }
            Toggle("Meeting kick-off (5 min before events)", isOn: $settings.prefs.meetingKickoff)
            Toggle("Calendar card on Home", isOn: Binding(get: { !settings.prefs.hiddenCards.contains(.calendar) },
                                                         set: { $0 ? settings.show(.calendar) : settings.hide(.calendar) }))
            Text("Events are read on this Mac only. The character shows a little watch when an event starts within 5 minutes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

// MARK: - About page

struct AboutSettingsSection: View {
    var body: some View {
        Section("About") {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppIdentity.name).font(.title2.weight(.semibold))
                    Text("Version \(Updater.currentVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("App", value: Bundle.main.bundlePath).textSelection(.enabled)
            LabeledContent("Data folder", value: Env.supportDir.path).textSelection(.enabled)
            HStack {
                Button("Open Data Folder") { NSWorkspace.shared.open(Env.supportDir) }
                Button("Third-Party Notices") {
                    if let u = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") { NSWorkspace.shared.open(u) }
                }
                Link("Source code", destination: URL(string: "https://github.com/glanceformac/glance")!)
            }
        }
        Section {
            HStack {
                Spacer()
                Button("Quit \(AppIdentity.name)") { AppDelegate.quitByUser() }
            }
        }
    }
}
