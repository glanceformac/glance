import AppKit
import Observation

enum CardKind: String, CaseIterable, Codable, Identifiable {
    case nowPlaying, weather, calendar, timer, football
    case claude // MARK: feat/claude-dev (shown only when Settings › Developer › Claude card is on)
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .weather: "Weather"
        case .calendar: "Calendar"
        case .timer: "Timer"
        case .football: "Football"
        case .claude: "Claude" // MARK: feat/claude-dev
        }
    }
    var symbol: String {
        switch self {
        case .nowPlaying: "music.note"
        case .weather: "cloud.sun"
        case .calendar: "calendar"
        case .timer: "timer"
        case .football: "soccerball"
        case .claude: "sparkle" // MARK: feat/claude-dev
        }
    }
}

enum ShortcutKind: String, CaseIterable, Codable, Identifiable {
    case youtube, messages, clipboard, recents, downloads, mail, notes, screenshot, mirror
    var id: String { rawValue }
    var title: String {
        switch self {
        case .youtube: "YouTube"
        case .messages: "Messages"
        case .clipboard: "Clipboard"
        case .recents: "Recents"
        case .downloads: "Downloads"
        case .mail: "Mail"
        case .notes: "Notes"
        case .screenshot: "Screenshot"
        case .mirror: "Mirror"
        }
    }
    var symbol: String {
        switch self {
        case .youtube: "play.rectangle"
        case .messages: "message"
        case .clipboard: "doc.on.clipboard"
        case .recents: "clock.arrow.circlepath"
        case .downloads: "arrow.down.circle"
        case .mail: "envelope"
        case .notes: "note.text"
        case .screenshot: "camera.viewfinder"
        case .mirror: "person.crop.square"
        }
    }
}

enum IslandTheme: String, Codable { case darkMatte, whiteMatte }
enum GlowStrength: String, Codable, CaseIterable { case subtle, normal, rich }
enum EqualiserStyle: String, Codable, CaseIterable { case fullWidth, rightOnly }
enum TouchBarStyle: String, Codable, CaseIterable { case equaliser, glow }
enum TempUnit: String, Codable, CaseIterable { case celsius, fahrenheit }

/// Everything that is persisted. Stored as one JSON blob in UserDefaults.
struct Prefs: Codable, Equatable {
    var cardOrder: [CardKind] = CardKind.allCases
    var hiddenCards: [CardKind] = []
    var shortcuts: [ShortcutKind] = [.youtube, .messages, .clipboard, .recents, .downloads]
    var quickLaunch: [String] = ["com.apple.finder", "com.apple.Safari", "com.apple.Notes", "com.apple.Terminal"]
    var theme: IslandTheme = .darkMatte
    var tempUnit: TempUnit = .celsius
    var useCurrentLocation = true
    var manualCity = ""
    var manualLat: Double? = nil
    var manualLon: Double? = nil
    var appLaunchPeeks = true
    var batteryPeeks = true
    var focusPeeks = true
    var lyrics = true
    var nowPlaying = true
    var claudeIntegration = true
    var desktopDials = true
    var setSystemAppearance = true
    var swapWallpaper = false
    var lightWallpaper = ""
    var darkWallpaper = ""
    var timerMinutes = 25
    var clipboardHistory = true
    var clipboardPaused = false
    var clipboardHotkey = true
    var pasteAfterCopy = false
    /// "Ignore copies from these apps" (bundle ids). Password managers by default; dictation apps
    /// found on this Mac are only suggested in Settings, never added without asking.
    var clipboardIgnoredApps: [String] = ClipboardFilter.passwordManagers
    /// Suggested apps the user said no to (not suggested again).
    var clipboardDismissedSuggestions: [String] = []
    /// Files copied in Finder are not kept (text copied in Finder, such as a file name, still is).
    var clipboardIgnoreFinderFiles = false
    /// Shelf: an item dragged out (and dropped somewhere) leaves the Shelf, unless it is pinned.
    var shelfRemoveAfterDrag = true
    // Look
    var glowEnabled = true
    var glowStyle: GlowStyle = .rainbow
    var glowWhenClosed = true
    var glowAnimateClosed = false
    var musicColors = true
    var accent: AccentTheme = .ocean
    var polish = true
    var haptics = true
    var uiSounds = false
    var islandHidden = false
    var showMenuBarIcon = true
    // Football
    var footballMode = true
    var footballLivePill = true
    var footballCard = true
    var footballTeam = FollowedTeam()   // picked in Settings › Football; none by default
    var matchdayTheme = true
    var spoilerFree = false
    var goalSound = false
    var celebrations = true
    var deployCelebrations = true
    /// Off for new installs (opt-in). Watches your GitHub account with the gh CLI login.
    var githubActivity = false
    /// Off for new installs (opt-in). Watches local git repos in ~/Desktop, ~/Developer, ~/Projects...
    var gitWatchFolders = false
    var focusMatch = true
    var focusScoreInPill = false
    var todoEnabled = true
    var endOfDayHour = 21
    var meetingKickoff = true
    var mirrorCircle = false
    var cinemaMode = false
    var barsFollowSound = false   // old screen-capture feature, removed
    var cinemaExtension = true
    var cinemaIntro = true
    var touchBarGlow = true
    var touchBarStyle: TouchBarStyle = .equaliser
    var touchBarButton = true
    var glowStrength: GlowStrength = .rich
    var cinemaProgress = true
    var cinemaTitle = false   // the title card is off by default
    var cinemaIntermission = true
    var cinemaHoverControls = true
    var cinemaInterior = true
    var cinemaWave = true
    var equaliserStyle: EqualiserStyle = .fullWidth
    var batterySaverAuto = true
    // Prompter
    var prompterSpeed: PrompterSpeed = .normal
    var prompterCountdown: PrompterCountdown = .three
    var prompterSize: PrompterSize = .m
    var prompterColour = "white"
    var prompterWidth = 520.0
    var prompterHeight = 190.0   // MARK: feat/prompter
    var prompterMirror = false
    var prompterHideFromSharing = true
    var prompterVoice: PrompterVoice = .off
    var toolsTab = true   // MARK: feat/productivity
    // MARK: feat/controls
    var keepAwakeDisplay = true           // "Keep screen on" while keeping the Mac awake (default on: the screen should not dim)
    var keepAwakeMenuBar = true           // cup item in the menu bar
    var islandStyle: IslandStyle = .notch
    var idlePillScale = 100.0             // % of the closed pill size
    var heightOffset = 0.0                // pt below the top edge (Pill only)
    var panelWidth = 640.0
    var panelMaxHeight = 372.0
    var pinOpen = false
    var autoCollapseDelay = 0.32          // seconds after the pointer leaves
    var hoverToOpen = true
    var paletteHotkey = true              // ⌃⌥K
    var knockKey: KnockKey = .rightOption
    // MARK: end feat/controls
    // MARK: feat/system-media
    var liveActivities = true
    var cameraGuard = true
    var cameraGuardMic = true
    var btConnectPeek = true
    var capsLockHUD = false
    var hudReplace = false
    var screenshotShelf = true
    var screenshotOCR = true
    var screenshotPeek = true
    var clipExtras = true
    var snapZones = false
    var systemMonitor = true
    var activityRings = false
    var stocksEnabled = false
    var stockSymbols = "AAPL, MSFT, ^GSPC"
    var deskPet = false
    /// Context rules ("what is useful when") and an optional manual override ("auto" = detect).
    var contextRules = true
    var contextOverride = "auto"
    /// One-time change: the Title card is off by default (also for existing settings).
    var cinemaTitleMigrated = true
    // MARK: feat/claude-dev
    var dev = DevPrefs()
    // MARK: wip/character
    var character = CharacterPrefs()

    init() {}
    // Tolerant decoding so new fields never wipe a saved layout.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Prefs()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        // Unknown card names (from other builds) are skipped instead of resetting the layout.
        cardOrder = (try? c.decodeIfPresent([String].self, forKey: .cardOrder))?.compactMap(CardKind.init(rawValue:)) ?? d.cardOrder
        for k in CardKind.allCases where !cardOrder.contains(k) { cardOrder.append(k) }
        hiddenCards = (try? c.decodeIfPresent([String].self, forKey: .hiddenCards))?.compactMap(CardKind.init(rawValue:)) ?? d.hiddenCards
        shortcuts = v(.shortcuts, d.shortcuts)
        quickLaunch = v(.quickLaunch, d.quickLaunch)
        theme = v(.theme, d.theme)
        tempUnit = v(.tempUnit, d.tempUnit)
        useCurrentLocation = v(.useCurrentLocation, d.useCurrentLocation)
        manualCity = v(.manualCity, d.manualCity)
        manualLat = v(.manualLat, d.manualLat)
        manualLon = v(.manualLon, d.manualLon)
        appLaunchPeeks = v(.appLaunchPeeks, d.appLaunchPeeks)
        batteryPeeks = v(.batteryPeeks, d.batteryPeeks)
        focusPeeks = v(.focusPeeks, d.focusPeeks)
        lyrics = v(.lyrics, d.lyrics)
        nowPlaying = v(.nowPlaying, d.nowPlaying)
        claudeIntegration = v(.claudeIntegration, d.claudeIntegration)
        desktopDials = v(.desktopDials, d.desktopDials)
        setSystemAppearance = v(.setSystemAppearance, d.setSystemAppearance)
        swapWallpaper = v(.swapWallpaper, d.swapWallpaper)
        lightWallpaper = v(.lightWallpaper, d.lightWallpaper)
        darkWallpaper = v(.darkWallpaper, d.darkWallpaper)
        timerMinutes = v(.timerMinutes, d.timerMinutes)
        clipboardHistory = v(.clipboardHistory, d.clipboardHistory)
        clipboardPaused = v(.clipboardPaused, d.clipboardPaused)
        clipboardHotkey = v(.clipboardHotkey, d.clipboardHotkey)
        pasteAfterCopy = v(.pasteAfterCopy, d.pasteAfterCopy)
        clipboardIgnoredApps = v(.clipboardIgnoredApps, d.clipboardIgnoredApps)
        clipboardDismissedSuggestions = v(.clipboardDismissedSuggestions, d.clipboardDismissedSuggestions)
        clipboardIgnoreFinderFiles = v(.clipboardIgnoreFinderFiles, d.clipboardIgnoreFinderFiles)
        shelfRemoveAfterDrag = v(.shelfRemoveAfterDrag, d.shelfRemoveAfterDrag)
        glowEnabled = v(.glowEnabled, d.glowEnabled)
        glowStyle = v(.glowStyle, d.glowStyle)
        glowWhenClosed = v(.glowWhenClosed, d.glowWhenClosed)
        glowAnimateClosed = v(.glowAnimateClosed, d.glowAnimateClosed)
        musicColors = v(.musicColors, d.musicColors)
        accent = v(.accent, d.accent)
        polish = v(.polish, d.polish)
        haptics = v(.haptics, d.haptics)
        uiSounds = v(.uiSounds, d.uiSounds)
        islandHidden = v(.islandHidden, d.islandHidden)
        showMenuBarIcon = v(.showMenuBarIcon, d.showMenuBarIcon)
        footballMode = v(.footballMode, d.footballMode)
        footballLivePill = v(.footballLivePill, d.footballLivePill)
        footballCard = v(.footballCard, d.footballCard)
        footballTeam = v(.footballTeam, d.footballTeam)
        matchdayTheme = v(.matchdayTheme, d.matchdayTheme)
        spoilerFree = v(.spoilerFree, d.spoilerFree)
        goalSound = v(.goalSound, d.goalSound)
        celebrations = v(.celebrations, d.celebrations)
        deployCelebrations = v(.deployCelebrations, d.deployCelebrations)
        githubActivity = v(.githubActivity, d.githubActivity)
        // Older builds had one switch for both; a migrated user keeps what that switch said.
        gitWatchFolders = v(.gitWatchFolders, githubActivity)
        focusMatch = v(.focusMatch, d.focusMatch)
        focusScoreInPill = v(.focusScoreInPill, d.focusScoreInPill)
        todoEnabled = v(.todoEnabled, d.todoEnabled)
        endOfDayHour = v(.endOfDayHour, d.endOfDayHour)
        meetingKickoff = v(.meetingKickoff, d.meetingKickoff)
        mirrorCircle = v(.mirrorCircle, d.mirrorCircle)
        cinemaMode = v(.cinemaMode, d.cinemaMode)
        barsFollowSound = v(.barsFollowSound, d.barsFollowSound)
        cinemaExtension = v(.cinemaExtension, d.cinemaExtension)
        cinemaIntro = v(.cinemaIntro, d.cinemaIntro)
        touchBarGlow = v(.touchBarGlow, d.touchBarGlow)
        touchBarStyle = v(.touchBarStyle, d.touchBarStyle)
        touchBarButton = v(.touchBarButton, d.touchBarButton)
        glowStrength = v(.glowStrength, d.glowStrength)
        cinemaProgress = v(.cinemaProgress, d.cinemaProgress)
        cinemaTitle = v(.cinemaTitle, d.cinemaTitle)
        cinemaIntermission = v(.cinemaIntermission, d.cinemaIntermission)
        cinemaHoverControls = v(.cinemaHoverControls, d.cinemaHoverControls)
        cinemaInterior = v(.cinemaInterior, d.cinemaInterior)
        cinemaWave = v(.cinemaWave, d.cinemaWave)
        equaliserStyle = v(.equaliserStyle, d.equaliserStyle)
        batterySaverAuto = v(.batterySaverAuto, d.batterySaverAuto)
        prompterSpeed = v(.prompterSpeed, d.prompterSpeed)
        prompterCountdown = v(.prompterCountdown, d.prompterCountdown)
        prompterSize = v(.prompterSize, d.prompterSize)
        prompterColour = v(.prompterColour, d.prompterColour)
        prompterWidth = v(.prompterWidth, d.prompterWidth)
        prompterHeight = v(.prompterHeight, d.prompterHeight)   // MARK: feat/prompter
        prompterMirror = v(.prompterMirror, d.prompterMirror)
        prompterHideFromSharing = v(.prompterHideFromSharing, d.prompterHideFromSharing)
        prompterVoice = v(.prompterVoice, d.prompterVoice)
        toolsTab = v(.toolsTab, d.toolsTab)
        // MARK: feat/controls
        keepAwakeDisplay = v(.keepAwakeDisplay, d.keepAwakeDisplay)
        keepAwakeMenuBar = v(.keepAwakeMenuBar, d.keepAwakeMenuBar)
        islandStyle = v(.islandStyle, d.islandStyle)
        idlePillScale = v(.idlePillScale, d.idlePillScale)
        heightOffset = v(.heightOffset, d.heightOffset)
        panelWidth = v(.panelWidth, d.panelWidth)
        panelMaxHeight = v(.panelMaxHeight, d.panelMaxHeight)
        pinOpen = v(.pinOpen, d.pinOpen)
        autoCollapseDelay = v(.autoCollapseDelay, d.autoCollapseDelay)
        hoverToOpen = v(.hoverToOpen, d.hoverToOpen)
        paletteHotkey = v(.paletteHotkey, d.paletteHotkey)
        knockKey = v(.knockKey, d.knockKey)
        // MARK: feat/system-media
        liveActivities = v(.liveActivities, d.liveActivities)
        cameraGuard = v(.cameraGuard, d.cameraGuard)
        cameraGuardMic = v(.cameraGuardMic, d.cameraGuardMic)
        btConnectPeek = v(.btConnectPeek, d.btConnectPeek)
        capsLockHUD = v(.capsLockHUD, d.capsLockHUD)
        hudReplace = v(.hudReplace, d.hudReplace)
        screenshotShelf = v(.screenshotShelf, d.screenshotShelf)
        screenshotOCR = v(.screenshotOCR, d.screenshotOCR)
        screenshotPeek = v(.screenshotPeek, d.screenshotPeek)
        clipExtras = v(.clipExtras, d.clipExtras)
        snapZones = v(.snapZones, d.snapZones)
        systemMonitor = v(.systemMonitor, d.systemMonitor)
        activityRings = v(.activityRings, d.activityRings)
        stocksEnabled = v(.stocksEnabled, d.stocksEnabled)
        stockSymbols = v(.stockSymbols, d.stockSymbols)
        deskPet = v(.deskPet, d.deskPet)
        contextRules = v(.contextRules, d.contextRules)
        contextOverride = v(.contextOverride, d.contextOverride)
        cinemaTitleMigrated = v(.cinemaTitleMigrated, false)
        if !cinemaTitleMigrated { cinemaTitle = false; cinemaTitleMigrated = true }

        dev = v(.dev, d.dev) // MARK: feat/claude-dev
        character = v(.character, d.character) // MARK: wip/character
    }
}

@Observable @MainActor
final class AppSettings {
    static let shared = AppSettings()
    private static let key = "IslandPrefs.v1"

    var prefs: Prefs {
        didSet {
            guard prefs != oldValue else { return }
            // Isolated test instances never write the real settings.
            if !Env.isolated, let data = try? JSONEncoder().encode(prefs) {
                Env.defaults.set(data, forKey: Self.key)
            }
            onChange?(oldValue, prefs)
        }
    }

    @ObservationIgnored var onChange: ((Prefs, Prefs) -> Void)?

    private init() {
        if let data = Env.defaults.data(forKey: Self.key),
           let p = try? JSONDecoder().decode(Prefs.self, from: data) {
            prefs = p
        } else {
            var p = Prefs()
            // New install: Notch on Macs with a camera notch, Pill elsewhere. A saved choice
            // (including one migrated from an older build) is always kept.
            p.islandStyle = HardwareNotch.present ? .notch : .pill
            prefs = p
        }
    }

    var visibleCards: [CardKind] {
        prefs.cardOrder.filter { !prefs.hiddenCards.contains($0) && ($0 != .football || (prefs.footballMode && prefs.footballCard && prefs.footballTeam.team != nil))
            && ($0 != .claude || (prefs.dev.usageEnabled && prefs.dev.usageCard)) } // MARK: feat/claude-dev: claude card gate
    }

    func hide(_ c: CardKind) {
        if !prefs.hiddenCards.contains(c) { prefs.hiddenCards.append(c) }
    }

    func show(_ c: CardKind) { prefs.hiddenCards.removeAll { $0 == c } }

    func move(_ c: CardKind, by delta: Int) {
        var vis = visibleCards
        guard let i = vis.firstIndex(of: c) else { return }
        let j = i + delta
        guard j >= 0, j < vis.count else { return }
        vis.swapAt(i, j)
        prefs.cardOrder = vis + prefs.cardOrder.filter { !vis.contains($0) }
    }

    func move(_ c: CardKind, before target: CardKind) {
        guard c != target else { return }
        var order = prefs.cardOrder
        order.removeAll { $0 == c }
        let idx = order.firstIndex(of: target) ?? order.count
        order.insert(c, at: idx)
        prefs.cardOrder = order
    }
}
