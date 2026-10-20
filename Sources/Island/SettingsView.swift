import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var cityField = AppSettings.shared.prefs.manualCity
    @State private var cityStatus = ""
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""

    @State private var page: SettingsPage = SettingsPage.initial

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPage.allCases, selection: $page) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            Divider()
            Form { pageContent }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(page)
        }
        .frame(minWidth: 760, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: SettingsPage.showNotification)) { n in
            if let p = n.object as? SettingsPage { page = p }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general:
                Section("General") {
                    Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: setLogin))
                    if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.secondary) }
                    Toggle("Show menu bar icon", isOn: $settings.prefs.showMenuBarIcon)
                    if !settings.prefs.showMenuBarIcon {
                        Text("To bring the icon back, open Glance again from Applications or Spotlight.").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Hide Glance", isOn: $settings.prefs.islandHidden)
                    Toggle("Desktop volume & brightness dials", isOn: $settings.prefs.desktopDials)
                    if !BrightnessControl.shared.available {
                        Text("Brightness control is not available on this display.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Peeks") {
                    Toggle("App launched", isOn: $settings.prefs.appLaunchPeeks)
                    Toggle("Charging & battery", isOn: $settings.prefs.batteryPeeks)
                    Toggle("Focus / Do Not Disturb (best effort)", isOn: $settings.prefs.focusPeeks)
                    if !FocusMonitor.shared.available {
                        Text("Focus state file isn't readable by Glance. Grant Full Disk Access to Glance to enable this, or leave it off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Theme") {
                    Picker("Glance", selection: $settings.prefs.theme) {
                        Text("Dark Matte").tag(IslandTheme.darkMatte)
                        Text("White Matte").tag(IslandTheme.whiteMatte)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Theme button also switches macOS Light / Dark", isOn: $settings.prefs.setSystemAppearance)
                    Toggle("Theme button also swaps wallpaper", isOn: $settings.prefs.swapWallpaper)
                    if settings.prefs.swapWallpaper {
                        wallpaperRow("Light wallpaper", path: $settings.prefs.lightWallpaper)
                        wallpaperRow("Dark wallpaper", path: $settings.prefs.darkWallpaper)
                        Text("Glance only changes which image is shown. It never deletes or moves your wallpapers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Focus timer") {
                    Stepper("Length: \(settings.prefs.timerMinutes) min", value: $settings.prefs.timerMinutes, in: 1...180)
                }
                Section("Quick launch apps") {
                    ForEach(settings.prefs.quickLaunch, id: \.self) { id in
                        HStack {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                                Text(FileManager.default.displayName(atPath: url.path))
                            } else {
                                Text(id).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { settings.prefs.quickLaunch.removeAll { $0 == id } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless)
                        }
                    }
                    Button("Add App…", action: addApp).disabled(settings.prefs.quickLaunch.count >= 6)
                }
                ControlsSettingsSections() // MARK: feat/controls
                Section("Context (what is useful when)") {
                    let ctx = IslandContext.shared
                    LabeledContent("Right now", value: ctx.current.title + (settings.prefs.contextOverride == "auto" ? "" : " (set by you)"))
                    Toggle("Context rules", isOn: $settings.prefs.contextRules)
                    if settings.prefs.contextRules {
                        Picker("Context", selection: $settings.prefs.contextOverride) {
                            Text("Automatic").tag("auto")
                            ForEach(IslandContext.Kind.allCases) { k in Text(k.title).tag(k.rawValue) }
                        }
                        Text("Watching a video: the Prompter waits, celebrations (except goals) play when it pauses or ends. Prompter running: Cinema and the equaliser are off, peeks wait, Claude approvals show as a small amber dot. In a meeting (camera in use or a calendar event now): no celebrations or sounds; the Prompter is allowed. Full-screen video: only Cinema in the pill. Battery saver: fewer animations.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
        case .island:
                IslandShapeSettingsSection()
                Section("Look") {
                    Toggle("Glow edge", isOn: $settings.prefs.glowEnabled)
                    if settings.prefs.glowEnabled {
                        Picker("Glow colours", selection: $settings.prefs.glowStyle) {
                            Text("Rainbow").tag(GlowStyle.rainbow)
                            Text("Accent").tag(GlowStyle.accent)
                            Text("Music").tag(GlowStyle.music)
                        }
                        .pickerStyle(.segmented)
                        Toggle("Glow when closed (subtle)", isOn: $settings.prefs.glowWhenClosed)
                        if settings.prefs.glowWhenClosed {
                            Toggle("Animate glow when closed (uses more GPU)", isOn: $settings.prefs.glowAnimateClosed)
                        }
                    }
                    Text("Claude requests always glow amber, Done flashes green, Deny flashes red. With Reduce Motion on, the glow stays still.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Colours and feel") {
                    Toggle("Colours from the music", isOn: $settings.prefs.musicColors)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accent colour")
                        HStack(spacing: 10) {
                            ForEach(AccentTheme.allCases) { a in
                                let selected = settings.prefs.accent == a
                                Button {
                                    settings.prefs.accent = a
                                    // Show the new accent right away, even with the island closed.
                                    IslandModel.shared.flash(.timer, seconds: 1.2)
                                } label: {
                                    VStack(spacing: 4) {
                                        ZStack {
                                            if a == .wallpaper {
                                                Circle().fill(AngularGradient(colors: [.pink, .orange, .yellow, .green, .blue, .purple, .pink], center: .center))
                                                Image(systemName: "photo").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                            } else {
                                                Circle().fill(Color(nsColor: a.color(dark: settings.prefs.theme == .darkMatte)))
                                            }
                                        }
                                        .frame(width: 24, height: 24)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-3))
                                        Text(a == .wallpaper ? "Wallpaper" : a.title).font(.caption2).foregroundStyle(selected ? .primary : .secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(a.title)
                            }
                        }
                    }
                    Picker("Mirror shape", selection: $settings.prefs.mirrorCircle) {
                        Text("Rounded square").tag(false)
                        Text("Circle").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text("Accent colours the timer, play button, selected tab, chips and badges; the glow uses it when Glow colours is Accent. While a track with artwork plays, Colours from the music take over the wash, bars, progress and lyrics. On your team's match days the matchday theme uses the team colour.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Glass & motion polish", isOn: $settings.prefs.polish)
                    Toggle("Trackpad haptics", isOn: $settings.prefs.haptics)
                    Toggle("Soft UI sounds", isOn: $settings.prefs.uiSounds)
                }
                SystemMediaSettings() // MARK: feat/system-media
        case .character:
                CharacterSettingsSections() // MARK: wip/character
        case .music:
                Section("Media") {
                    Toggle("Now Playing", isOn: $settings.prefs.nowPlaying)
                    Toggle("Synced lyrics (LRCLIB)", isOn: $settings.prefs.lyrics)
                }
        case .cinema:
                Section("Cinema mode") {
                    Toggle("Cinema mode (Ambilight, via the Chrome extension)", isOn: $settings.prefs.cinemaExtension)
                    if settings.prefs.cinemaExtension {
                        Toggle("Cinema intro and outro", isOn: $settings.prefs.cinemaIntro)
                        HStack {
                            Button("Preview intro") { ChromeAmbilight.shared.previewSimulated(seconds: IntroH.duration + 3) }
                            Button("Preview outro") {
                                IslandModel.shared.setExpanded(false)
                                IslandModel.shared.celebrate(.cinemaOutro)
                                TouchBarGlow.shared.previewOutro()
                            }
                        }
                        Toggle("Progress line and \"Ends at\" time", isOn: $settings.prefs.cinemaProgress)
                        Toggle("Title card when a video starts", isOn: $settings.prefs.cinemaTitle)
                        Toggle("Intermission when paused", isOn: $settings.prefs.cinemaIntermission)
                        Toggle("Video controls on hover (click opens the panel)", isOn: $settings.prefs.cinemaHoverControls)
                        Toggle("Lit from inside", isOn: $settings.prefs.cinemaInterior)
                        Toggle("Equaliser with bass thump", isOn: $settings.prefs.cinemaWave)
                        Picker("Equaliser style", selection: $settings.prefs.equaliserStyle) {
                            Text("Full width").tag(EqualiserStyle.fullWidth)
                            Text("Right only").tag(EqualiserStyle.rightOnly)
                        }
                        .pickerStyle(.segmented)
                        Toggle("Battery saver: automatic (on battery or Low Power Mode)", isOn: $settings.prefs.batterySaverAuto)
                        Picker("Glow strength", selection: $settings.prefs.glowStrength) {
                            Text("Subtle").tag(GlowStrength.subtle)
                            Text("Normal").tag(GlowStrength.normal)
                            Text("Rich").tag(GlowStrength.rich)
                        }
                        .pickerStyle(.segmented)
                        Text(ChromeAmbilight.shared.connected
                             ? "Extension connected · \(ChromeAmbilight.shared.domain.isEmpty ? "no video" : ChromeAmbilight.shared.domain) · \(ChromeAmbilight.shared.method)"
                             : "Install the Glance for Mac Chrome extension (see README). It sends only colours, sound levels and play state; no screen capture.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Preview Cinema (simulated)")
                        Spacer()
                        Button("Preview") { ChromeAmbilight.shared.previewSimulated() }
                    }
                }
        case .shelf:
                Section("Shelf") {
                    Toggle("Remove items after dragging out", isOn: $settings.prefs.shelfRemoveAfterDrag)
                    Text("When you drop a Shelf item into another app or folder, it leaves the Shelf (Undo for 5 seconds). Pinned items stay. The file itself is never moved or deleted.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Files on the Shelf are references (bookmarks), not copies: if you delete or move the original, the Shelf follows or shows it as missing. Removing an item never touches the original file. Dropped images and text without a file are stored privately in ~/Library/Application Support/Glance.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Clear Shelf…", role: .destructive) {
                            let a = NSAlert()
                            a.messageText = "Remove all items from the Shelf?"
                            a.informativeText = "The original files are not touched; only the Shelf list is cleared."
                            a.addButton(withTitle: "Clear Shelf")
                            a.addButton(withTitle: "Cancel")
                            if a.runModal() == .alertFirstButtonReturn { ShelfStore.shared.clear() }
                        }
                    }
                }
        case .clipboard:
                Section("Clipboard") {
                    Toggle("Pause clipboard history", isOn: $settings.prefs.clipboardPaused)
                    Toggle("⌃⌥V opens Clipboard", isOn: $settings.prefs.clipboardHotkey)
                    Toggle("Paste into the front app after choosing an item", isOn: Binding(
                        get: { settings.prefs.pasteAfterCopy },
                        set: { on in
                            settings.prefs.pasteAfterCopy = on
                            if on && !Env.noPermissions {
                                // Simulating ⌘V needs Accessibility; this shows the system prompt once.
                                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                                _ = AXIsProcessTrustedWithOptions(opts)
                            }
                        }))
                    Text(settings.prefs.pasteAfterCopy && !AXIsProcessTrusted()
                         ? "Needs Accessibility: System Settings › Privacy & Security › Accessibility › Glance. Until then, items are only copied."
                         : "Keeps the last 50 copies plus your Saved snippets, only on this Mac (~/Library/Application Support/Glance, private to your user). Items marked concealed, transient or auto-generated, repeats of the newest item and single characters are never stored.")
                        .font(.caption).foregroundStyle(.secondary)
                    ClipboardIgnoreSettings()
                    HStack {
                        Spacer()
                        Button("Clear History", role: .destructive) { ClipboardStore.shared.clearHistory() }
                    }
                }
        case .calendar:
                CalendarSettingsSection()
        case .tools:
                ToolsSettingsSection()   // MARK: feat/productivity
        case .weather:
                Section("Weather") {
                    Picker("Units", selection: $settings.prefs.tempUnit) {
                        Text("Celsius").tag(TempUnit.celsius)
                        Text("Fahrenheit").tag(TempUnit.fahrenheit)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Use current location", isOn: $settings.prefs.useCurrentLocation)
                    HStack {
                        TextField("City (used if location is off or denied)", text: $cityField)
                            .onSubmit(saveCity)
                        Button("Set", action: saveCity)
                    }
                    if !cityStatus.isEmpty { Text(cityStatus).font(.caption).foregroundStyle(.secondary) }
                }
        case .prompter:
                PrompterSettingsSection()   // MARK: feat/prompter
        case .claude:
                Section("Claude Code") {
                    Toggle("Show Claude Code requests and Done peeks", isOn: $settings.prefs.claudeIntegration)
                    Text("Socket: \(ClaudeServer.socketPath)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Glance never edits your Claude Code settings. To connect it, add the hooks from the setup guide to ~/.claude/settings.json. The hook helper is \(Bundle.main.bundlePath)/Contents/MacOS/glance-hook.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Link("Claude Code hooks setup guide", destination: URL(string: "https://github.com/glanceformac/glance/blob/main/INSTALL-HOOKS.md")!)
                        .font(.caption)
                }
                DeveloperSettingsSection() // MARK: feat/claude-dev
        case .football:
                Section("Football") {
                    Toggle("Football mode (live scores for a team you pick)", isOn: $settings.prefs.footballMode)
                    if settings.prefs.footballMode {
                        FootballTeamPicker(followed: $settings.prefs.footballTeam)
                        Toggle("Live score in the pill during matches", isOn: $settings.prefs.footballLivePill)
                        Toggle("Football card on Home", isOn: $settings.prefs.footballCard)
                        Toggle("Matchday theme (team colours on match days)", isOn: $settings.prefs.matchdayTheme)
                        Toggle("Spoiler-free (no live score or goal alerts; replay after full time)", isOn: $settings.prefs.spoilerFree)
                        Toggle("Goal sound (system sound)", isOn: $settings.prefs.goalSound)
                    }
                    Toggle("Celebrations (football-style animations)", isOn: $settings.prefs.celebrations)
                    Toggle("Celebrate commits, pushes and deploys from Claude Code", isOn: $settings.prefs.deployCelebrations)
                    Toggle("GitHub activity (uses your gh CLI login, checks every 2 min)", isOn: $settings.prefs.githubActivity)
                    Toggle("Celebrate commits in local git folders (~/Desktop, ~/Developer, ~/Projects, ~/code, ~/src, ~/repos)", isOn: $settings.prefs.gitWatchFolders)
                    Text("Both are off until you turn them on. Watching ~/Desktop may make macOS ask for access to that folder.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(GitHubActivity.shared.status).font(.caption).foregroundStyle(.secondary)
                    Text(GitWatch.shared.status).font(.caption).foregroundStyle(.secondary)   // MARK: wip/cinema-h
                    Toggle("Focus timer as a match (halves, half-time, full-time)", isOn: $settings.prefs.focusMatch)
                    if settings.prefs.focusMatch {
                        Picker("Half length", selection: $settings.prefs.timerMinutes) {
                            Text("25 min").tag(25)
                            Text("45 min").tag(45)
                        }
                        .pickerStyle(.segmented)
                        Toggle("Show \"Focus 3–0 Distractions\" in the pill", isOn: $settings.prefs.focusScoreInPill)
                    }
                    Toggle("Daily scoreboard (Today tab)", isOn: $settings.prefs.todoEnabled)
                    if settings.prefs.todoEnabled {
                        Stepper("Full-time whistle at \(settings.prefs.endOfDayHour):00", value: $settings.prefs.endOfDayHour, in: 15...23)
                    }
                    Toggle("Meeting kick-off (5 min before events)", isOn: $settings.prefs.meetingKickoff)
                    DisclosureGroup("Preview animations") {
                        ForEach(Array(CelebrationKind.previews.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Text(item.0)
                                Spacer()
                                Button("Preview") { IslandModel.shared.celebrate(item.1) }
                            }
                        }
                        HStack {
                            Text("Opponent goal (shake + deflate)")
                            Spacer()
                            Button("Preview") { IslandModel.shared.setExpanded(false); IslandModel.shared.shakePill() }
                        }
                    }
                    Text("Club badges come from ESPN's public feed and are trademarks of their clubs; they are cached for personal use only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
        case .touchbar:
                Section("Touch Bar") {
                    Toggle("Control Strip button (show / hide Glance)", isOn: $settings.prefs.touchBarButton)
                    Text("Helper: \(IslandBarHelper.status)").font(.caption).foregroundStyle(.secondary)
                    Toggle("Touch Bar during Cinema mode", isOn: $settings.prefs.touchBarGlow)
                    if settings.prefs.touchBarGlow {
                        Picker("Touch Bar style", selection: $settings.prefs.touchBarStyle) {
                            Text("Equaliser").tag(TouchBarStyle.equaliser)
                            Text("Colour glow").tag(TouchBarStyle.glow)
                        }
                        .pickerStyle(.segmented)
                    }
                    if !TouchBarAPI.available { Text("Touch Bar APIs not available on this Mac.").font(.caption).foregroundStyle(.secondary) }
                }
                CharacterTouchBarSettingsSection() // MARK: wip/character
        case .updates:
                UpdateSettingsSection()
        case .about:
                AboutSettingsSection()
        }
    }

    private func saveCity() {
        let name = cityField
        cityStatus = "Looking up…"
        Task {
            let ok = await Weather.shared.setCity(name)
            cityStatus = ok ? "Using \(AppSettings.shared.prefs.manualCity)" : "City not found"
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            try OpenAtLogin.set(on)
            loginError = ""
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginError = "Approve Glance in System Settings › General › Login Items."
        }
    }

    private func wallpaperRow(_ title: String, path: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(path.wrappedValue.isEmpty ? "None" : (path.wrappedValue as NSString).lastPathComponent)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Choose…") {
                let p = NSOpenPanel()
                p.allowedContentTypes = [.image]
                p.allowsMultipleSelection = false
                if p.runModal() == .OK, let u = p.url { path.wrappedValue = u.path }
            }
        }
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        if p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier,
           !settings.prefs.quickLaunch.contains(id) {
            settings.prefs.quickLaunch.append(id)
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// The full Settings window. While it is open Glance has a Dock icon and a small menu bar
    /// (so it feels like a normal app and ⌘C / ⌘V work in text fields); closing it goes back to
    /// a menu bar app.
    func show(page: SettingsPage? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "\(AppIdentity.name) Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.contentMinSize = NSSize(width: 760, height: 560)
            w.setFrameAutosaveName("GlanceSettingsWindow")
            w.delegate = self
            if !w.setFrameUsingName("GlanceSettingsWindow") { w.center() }
            window = w
        }
        if let page { NotificationCenter.default.post(name: SettingsPage.showNotification, object: page) }
        IslandModel.shared.setExpanded(false)
        AppMenu.becomeRegular()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppMenu.becomeAccessory()
    }
}

// MARK: - Football team picker (teams are loaded from the data source at runtime)

struct FootballTeamPicker: View {
    @Binding var followed: FollowedTeam
    @State private var teams: [TeamInfo] = []
    @State private var loading = false
    @State private var failed = false
    private var source: FootballDataSource { FootballService.shared.source }

    var body: some View {
        Picker("League", selection: $followed.league) {
            ForEach(source.leagues) { Text($0.name).tag($0.id) }
        }
        .onChange(of: followed.league) { _, _ in teams = []; load() }
        HStack {
            Picker("Team", selection: Binding(get: { followed.team?.id ?? "" }, set: { id in
                followed.team = teams.first { $0.id == id }
            })) {
                Text("None").tag("")
                if let t = followed.team, !teams.contains(where: { $0.id == t.id }) { Text(t.name).tag(t.id) }
                ForEach(teams) { Text($0.name).tag($0.id) }
            }
            if loading { ProgressView().controlSize(.small) }
        }
        .onAppear { if teams.isEmpty { load() } }
        Text(failed ? "Could not load teams. Check your connection and reopen Settings."
             : "Scores come from \(source.name). It is not an official API and may stop working. Club names and badges belong to their clubs; badges are downloaded when shown and cached on this Mac only.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func load() {
        let league = followed.league
        loading = true; failed = false
        Task {
            let list = await source.teams(league: league)
            guard league == followed.league else { return }
            teams = list
            failed = list.isEmpty
            loading = false
        }
    }
}
