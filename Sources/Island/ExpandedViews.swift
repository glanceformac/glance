import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExpandedContent: View {
    let theme: Theme
    /// MARK: wip/cinema-h: the old page leaves almost at once and the new one fades in a moment
    /// later, so two pages are never drawn over each other (the "ghost" of the previous tab).
    static let pageTransition = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.16).delay(0.05)),
        removal: .opacity.animation(.easeIn(duration: 0.05)))
    private let model = IslandModel.shared
    private let settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            TopRow(theme: theme)
                .frame(height: 30)
                .padding(.top, 4)
            switch model.page {
            case .clipboard:
                ClipboardView(theme: theme)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                    .transition(Self.pageTransition)
            case .prompter:
                PrompterPage(theme: theme)
                    .padding(.top, 10)
                    .transition(Self.pageTransition)
            case .tools:   // MARK: feat/productivity
                ToolsPage(theme: theme)
                    .padding(.top, 10)
                    .transition(Self.pageTransition)
            case .today:
                TodayView(theme: theme)
                    .padding(.top, 10)
                    .transition(Self.pageTransition)
            case .system: // MARK: feat/system-media
                SystemPage(theme: theme)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                    .transition(Self.pageTransition)
            case .dev: // MARK: feat/claude-dev
                DevPage(theme: theme)
                    .padding(.top, 10)
                    .transition(Self.pageTransition)
            case .shelf:
                ShelfView(theme: theme)
                    .frame(height: 178)
                    .padding(.top, 8)
                    .transition(Self.pageTransition)
                Spacer(minLength: 0)
            default:
                Group {
                    switch model.page {
                    case .mirror: MirrorView(theme: theme)
                    case .volume: SoundPage(theme: theme) // MARK: feat/system-media
                    case .brightness: SliderPage(theme: theme, kind: .brightness)
                    default:
                        // MARK: wip/character: the character stands on the left of Home.
                        HStack(spacing: 8) {
                            if CharacterEngine.shared.showing {
                                // As tall as the cards beside it (the row is 132 pt), centred in its column.
                                CharacterRig(darkBackdrop: theme.dark, fitArt: true)
                                    .frame(width: 112)
                                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
                            }
                            // Shadow clones: while Claude Code subagents run, their clones take over
                            // the cards area (one cell each); the cards come back once they are gone.
                            if CharacterEngine.shared.clonesShowing {
                                CloneStrip()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .leading)))
                            } else {
                                CardsRow(theme: theme)
                                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .trailing)))
                            }
                        }
                    }
                }
                .frame(height: 132)
                .padding(.top, 8)
                .transition(Self.pageTransition)
                BottomRow(theme: theme)
                    .frame(height: 36)
                    .padding(.top, 10)
                    .transition(Self.pageTransition)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 26)
    }
}

// MARK: - Top row

struct IconButton: View {
    let symbol: String
    let theme: Theme
    var active = false
    var help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(active ? theme.accent : (hover ? theme.primary : theme.secondary))
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.card.opacity(hover || active ? 1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct TopRow: View {
    let theme: Theme
    private let model = IslandModel.shared
    private let settings = AppSettings.shared

    /// Width at the top centre that must stay clear (a hardware notch, or a black notch shape).
    /// 0 on Macs without a notch. Features that draw a notch can raise it via `extraReserve`.
    @MainActor static var extraReserve: CGFloat = 0
    @MainActor static var centreReserve: CGFloat {
        var r = extraReserve
        if let s = NSScreen.screens.first, s.safeAreaInsets.top > 0,
           let l = s.auxiliaryTopLeftArea, let rr = s.auxiliaryTopRightArea {
            r = max(r, s.frame.width - l.width - rr.width + 16)
        }
        return r
    }

    var body: some View {
        let reserve = Self.centreReserve
        if reserve > 0 {
            // Two equal halves around a clear centre gap, each compacting itself to fit.
            HStack(spacing: 0) {
                ViewThatFits(in: .horizontal) { tools(compact: false); tools(compact: true) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: reserve, height: 1)
                ViewThatFits(in: .horizontal) { trailing(apps: 4); trailing(apps: 2); trailing(apps: 0) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                row(compact: false, apps: 4)
                row(compact: true, apps: 4)
                row(compact: true, apps: 2)
                row(compact: true, apps: 0)
            }
        }
    }

    private func row(compact: Bool, apps: Int) -> some View {
        HStack(spacing: 2) {
            tools(compact: compact)
            Spacer(minLength: 8)
            trailing(apps: apps)
        }
    }

    private func trailing(apps: Int) -> some View {
        HStack(spacing: 8) {
            TabSwitch(theme: theme)
            if apps > 0 {
                HStack(spacing: 8) {
                    ForEach(Array(settings.prefs.quickLaunch.prefix(apps)), id: \.self) { id in
                        QuickLaunchIcon(bundleID: id)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .fixedSize()
    }

    /// Full: every tool icon. Compact: the everyday ones, the rest in a "More" menu.
    private func tools(compact: Bool) -> some View {
        HStack(spacing: 2) {
            IconButton(symbol: "gearshape", theme: theme, help: "Settings") { AppDelegate.shared?.showSettings() }
            if !compact {
                IconButton(symbol: "square.grid.2x2", theme: theme, help: "Apps") { openApps() }
                IconButton(symbol: "slider.horizontal.3", theme: theme, active: model.editing, help: "Edit layout") { editLayout() }
            }
            IconButton(symbol: VolumeControl.shared.muted ? "speaker.slash" : "speaker.wave.2", theme: theme,
                       active: model.page == .volume, help: "Volume") { toggle(.volume) }
            if BrightnessControl.shared.available {
                IconButton(symbol: "sun.max", theme: theme, active: model.page == .brightness, help: "Brightness") { toggle(.brightness) }
            }
            KeepAwakeButton(theme: theme) // MARK: feat/controls (always visible: it shows its state)
            if !compact {
                IconButton(symbol: "circle.lefthalf.filled", theme: theme, help: "Switch Dark / White Matte") { ThemeSwitcher.toggle() }
                IconButton(symbol: "person.crop.square", theme: theme, active: model.page == .mirror, help: "Mirror") { toggle(.mirror) }
                IconButton(symbol: "text.viewfinder", theme: theme, active: model.page == .prompter, help: "Prompter") { toggle(.prompter) }
                if settings.prefs.dev.devPage { // MARK: feat/claude-dev
                    IconButton(symbol: "terminal", theme: theme, active: model.page == .dev, help: "Developer: Claude usage, Terminal, Homebrew") { toggle(.dev) }
                }
            } else {
                Menu {
                    Button("Apps") { openApps() }
                    Button("Edit layout") { editLayout() }
                    Button("Switch Dark / White Matte") { ThemeSwitcher.toggle() }
                    Button("Mirror") { toggle(.mirror) }
                    Button("Prompter") { toggle(.prompter) }
                    if settings.prefs.dev.devPage { Button("Developer") { toggle(.dev) } }   // MARK: feat/claude-dev
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(theme.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 28, height: 26)
                .help("More")
                .accessibilityLabel("More")
            }
        }
        .fixedSize()
    }

    private func openApps() {
        Shortcuts.openApp("com.apple.launchpad.launcher")
        model.setExpanded(false)
    }
    private func editLayout() {
        withAnimation(IslandModel.openSpring) {
            model.page = .widgets
            model.editing.toggle()
        }
    }

    private func toggle(_ p: ExpandedPage) {
        withAnimation(IslandModel.openSpring) {
            model.editing = false
            model.page = model.page == p ? .widgets : p
        }
    }
}

struct QuickLaunchIcon: View {
    let bundleID: String
    @State private var hover = false
    private var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    var body: some View {
        if let url {
            Button {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                IslandModel.shared.setExpanded(false)
            } label: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 22, height: 22)
                    .scaleEffect(hover ? 1.15 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
    }
}

// MARK: - Cards row

struct CardsRow: View {
    let theme: Theme
    private let model = IslandModel.shared
    private let settings = AppSettings.shared
    private let np = NowPlaying.shared

    private var cards: [CardKind] {
        settings.visibleCards.filter { $0 != .nowPlaying || np.hasMedia || model.editing }
    }

    var body: some View {
        let cards = self.cards
        GeometryReader { geo in
            let spacing: CGFloat = 10
            let weights = cards.map { $0 == .nowPlaying ? 1.75 : 1.0 }
            let total = weights.reduce(0, +)
            let unit = total > 0 ? (geo.size.width - spacing * CGFloat(max(cards.count - 1, 0))) / total : 0
            HStack(spacing: spacing) {
                if cards.isEmpty {
                    Text(model.editing ? "All cards hidden. Add them back below." : "No cards. Open edit mode to add some.")
                        .font(.system(size: 12)).foregroundStyle(theme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(Array(cards.enumerated()), id: \.element) { idx, kind in
                    CardContainer(kind: kind, theme: theme, index: idx, count: cards.count) {
                        switch kind {
                        case .nowPlaying: NowPlayingCard(theme: theme)
                        case .weather: WeatherCard(theme: theme)
                        case .calendar: CalendarCard(theme: theme)
                        case .timer: TimerCard(theme: theme)
                        case .football: FootballCard(theme: theme)
                        case .claude: ClaudeUsageCard(theme: theme) // MARK: feat/claude-dev
                        }
                    }
                    .frame(width: unit * weights[idx])
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
        }
    }
}

struct CardContainer<Content: View>: View {
    let kind: CardKind
    let theme: Theme
    let index: Int
    let count: Int
    @ViewBuilder let content: () -> Content
    private let model = IslandModel.shared
    @State private var wiggle = false
    @State private var dropTarget = false
    @State private var appeared = false
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            content()
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.card.opacity(hover && AppSettings.shared.prefs.polish ? 1.5 : 1))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(dropTarget ? theme.primary.opacity(0.5) : theme.cardStroke, lineWidth: dropTarget ? 1.5 : 0.5))
                )
                .opacity(model.editing ? 0.5 : 1)
                .allowsHitTesting(!model.editing)

            if model.editing {
                Button {
                    withAnimation(IslandModel.openSpring) { AppSettings.shared.hide(kind) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 17))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.45))
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .help("Remove \(kind.title)")
                .transition(.scale.combined(with: .opacity))

                HStack(spacing: 10) {
                    if index > 0 { arrow("chevron.left", -1) }
                    if index < count - 1 { arrow("chevron.right", 1) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .rotationEffect(.degrees(model.editing ? (wiggle ? 0.8 : -0.8) : 0))
        // Cards stagger in on expand (35 ms apart).
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
        .onAppear {
            guard AppSettings.shared.prefs.polish, !Look.shared.reduceMotion else { appeared = true; return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78).delay(0.06 + Double(index) * 0.035)) { appeared = true }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onChange(of: model.editing, initial: true) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true).delay(Double(index) * 0.03)) { wiggle = true }
            } else {
                withAnimation(.easeOut(duration: 0.1)) { wiggle = false }
            }
        }
        .onDrag {
            NSItemProvider(object: kind.rawValue as NSString)
        }
        .onDrop(of: [.text], isTargeted: $dropTarget) { providers in
            guard model.editing, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let raw = obj as? String, let src = CardKind(rawValue: raw) else { return }
                Task { @MainActor in
                    withAnimation(IslandModel.openSpring) { AppSettings.shared.move(src, before: kind) }
                }
            }
            return true
        }
    }

    private func arrow(_ symbol: String, _ delta: Int) -> some View {
        Button {
            withAnimation(IslandModel.openSpring) { AppSettings.shared.move(kind, by: delta) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(theme.dark ? Color(white: 0.28) : Color(white: 0.88)))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .help(delta < 0 ? "Move left" : "Move right")
    }
}

// MARK: - Cards

struct NowPlayingCard: View {
    let theme: Theme
    private let np = NowPlaying.shared

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(image: np.artwork, size: 84, corner: 14)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                .onTapGesture { openPlayer() }
            VStack(alignment: .leading, spacing: 2) {
                Text(np.hasMedia ? np.title : "Nothing playing")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary).lineLimit(1)
                Text(np.artist)
                    .font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(1)
                Spacer(minLength: 4)
                ProgressLine(theme: theme)
                    .frame(height: 3)
                Spacer(minLength: 6)
                HStack(spacing: 0) {
                    control("backward.fill", 13) { np.send(.previous) }
                    Spacer(minLength: 0)
                    control(np.isPlaying ? "pause.fill" : "play.fill", 19) { np.send(.togglePlayPause) }
                    Spacer(minLength: 0)
                    control("forward.fill", 13) { np.send(.next) }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func openPlayer() {
        guard !np.bundleID.isEmpty else { return }
        Shortcuts.openApp(np.bundleID)
    }

    private func control(_ s: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: s)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(theme.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct ProgressLine: View {
    let theme: Theme
    private let np = NowPlaying.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: np.isPlaying ? 1 : 3600)) { _ in
            GeometryReader { g in
                let frac = np.duration > 0 ? min(max(np.elapsed / np.duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.tertiary.opacity(0.6))
                    Capsule().fill(AppSettings.shared.prefs.musicColors ? Look.shared.musicPrimary : theme.primary.opacity(0.85))
                        .frame(width: g.size.width * frac)
                        .animation(.easeInOut(duration: 0.8), value: Look.shared.paletteKey)
                }
            }
        }
    }
}

struct WeatherCard: View {
    let theme: Theme
    private let w = Weather.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(w.city.isEmpty ? "Weather" : w.city)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primary).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: w.symbol + ".fill")
                    .symbolRenderingMode(theme.dark ? .multicolor : .hierarchical)
                    .foregroundStyle(theme.secondary)
                    .font(.system(size: 16))
            }
            Spacer(minLength: 0)
            if let t = w.temperature {
                Text("\(Int(t.rounded()))°")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(theme.primary)
                    .contentTransition(.numericText())
                Text(w.condition).font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(1)
                if let h = w.high, let l = w.low {
                    Text("H:\(Int(h.rounded()))°  L:\(Int(l.rounded()))°")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondary)
                }
            } else {
                Text(w.status).font(.system(size: 11)).foregroundStyle(theme.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

struct CalendarCard: View {
    let theme: Theme
    private let cal = CalendarService.shared

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            Text(now.formatted(.dateTime.weekday(.wide)).uppercased())
                .font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 1, green: 0.32, blue: 0.3))
            Text(now.formatted(.dateTime.day()))
                .font(.system(size: 32, weight: .light)).foregroundStyle(theme.primary)
            Spacer(minLength: 0)
            if cal.accessDenied {
                Text("Allow Calendar access in System Settings").font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(2)
            } else if let t = cal.nextTitle {
                HStack(alignment: .top, spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(cal.nextColor).frame(width: 3, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.primary).lineLimit(1)
                        Text(cal.nextTime ?? "").font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(1)
                    }
                }
            } else {
                Text("No more events").font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { Shortcuts.openApp("com.apple.iCal"); IslandModel.shared.setExpanded(false) }
    }
}

struct TimerCard: View {
    let theme: Theme
    private let timer = FocusTimer.shared
    private var match: Bool { AppSettings.shared.prefs.focusMatch }

    var body: some View {
        VStack(spacing: 4) {
            if match {
                Text(timer.phaseLabel.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(timer.phase == .halfTime ? .orange : theme.accent)
            }
            ZStack {
                Circle().stroke(theme.tertiary.opacity(0.5), lineWidth: 3)
                Circle().trim(from: 0, to: timer.progress)
                    .stroke(timer.phase == .halfTime ? Color.orange : theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: timer.progress)
                Text(timer.label)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.primary)
                    .contentTransition(.numericText(countsDown: true))
            }
            .frame(width: match ? 54 : 66, height: match ? 54 : 66)
            HStack(spacing: 8) {
                Button { withAnimation { timer.toggle() } } label: {
                    Image(systemName: timer.running ? "pause.fill" : "play.fill")
                        .font(.system(size: 11)).foregroundStyle(theme.onAccent)
                        .frame(width: 26, height: 20)
                        .background(Capsule().fill(theme.accent))
                }.buttonStyle(PressScaleStyle()).help(timer.running ? "Pause" : "Start focus timer")
                Button { withAnimation { timer.reset() } } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.primary)
                        .frame(width: 24, height: 20)
                        .background(Capsule().fill(theme.card))
                }.buttonStyle(PressScaleStyle()).help(match ? "Stop (an early stop counts as a Distraction)" : "Reset")
                if match {
                    Button { FocusMatch.shared.distraction() } label: {
                        Image(systemName: "exclamationmark.bubble")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.primary)
                            .frame(width: 24, height: 20)
                            .background(Capsule().fill(theme.card))
                    }.buttonStyle(PressScaleStyle()).help("Log a Distraction")
                }
            }
            if match {
                Text("\(FocusMatch.shared.today.focus)–\(FocusMatch.shared.today.distractions)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(theme.secondary)
                    .help(FocusMatch.shared.scoreLine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Bottom row (lyrics + shortcut chips, or edit tray)

struct BottomRow: View {
    let theme: Theme
    private let model = IslandModel.shared
    private let settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 10) {
            if model.editing {
                EditTray(theme: theme)
            } else {
                let compact = NowPlaying.shared.hasMedia && settings.prefs.lyrics && !Lyrics.shared.lines.isEmpty
                LyricsLine(theme: theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    ForEach(settings.prefs.shortcuts) { s in
                        Chip(kind: s, theme: theme, editing: false, compact: compact)
                    }
                }
                .fixedSize()
            }
        }
    }
}

struct Chip: View {
    let kind: ShortcutKind
    let theme: Theme
    let editing: Bool
    var compact = false
    @State private var hover = false

    var body: some View {
        Button {
            if editing {
                withAnimation(IslandModel.openSpring) { AppSettings.shared.prefs.shortcuts.removeAll { $0 == kind } }
                ClipboardStore.shared.updateRunning()
            } else {
                Shortcuts.run(kind)
            }
        } label: {
            HStack(spacing: 4) {
                if editing {
                    Image(systemName: "minus.circle.fill").font(.system(size: 10))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, Color(white: 0.45))
                }
                Image(systemName: kind.symbol).font(.system(size: compact ? 11 : 10, weight: .medium))
                if !compact { Text(kind.title).font(.system(size: 11, weight: .medium)) }
            }
            .foregroundStyle(hover ? theme.primary : theme.primary.opacity(0.85))
            .padding(.horizontal, compact ? 7 : 9)
            .frame(height: 24)
            .background(Capsule().fill(theme.card.opacity(hover ? 1.8 : 1)))
            .overlay(Capsule().strokeBorder(hover ? theme.accent.opacity(0.6) : theme.cardStroke, lineWidth: hover ? 1 : 0.5))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hover = $0 }
        .help(editing ? "Remove \(kind.title)" : kind.title)
    }
}

struct EditTray: View {
    let theme: Theme
    private let settings = AppSettings.shared
    private let model = IslandModel.shared

    var body: some View {
        let hidden = settings.prefs.cardOrder.filter { settings.prefs.hiddenCards.contains($0) }
        let missingChips = ShortcutKind.allCases.filter { !settings.prefs.shortcuts.contains($0) }
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(settings.prefs.shortcuts) { s in
                        Chip(kind: s, theme: theme, editing: true)
                    }
                    if settings.prefs.shortcuts.isEmpty {
                        Text("No shortcuts").font(.system(size: 11)).foregroundStyle(theme.tertiary)
                    }
                }
            }
            if !hidden.isEmpty || !missingChips.isEmpty {
                Menu {
                    if !hidden.isEmpty {
                        Section("Cards") {
                            ForEach(hidden) { c in
                                Button { withAnimation(IslandModel.openSpring) { settings.show(c) } } label: {
                                    Label(c.title, systemImage: c.symbol)
                                }
                            }
                        }
                    }
                    if !missingChips.isEmpty {
                        Section("Shortcuts") {
                            ForEach(missingChips) { k in
                                Button {
                                    withAnimation(IslandModel.openSpring) { settings.prefs.shortcuts.append(k) }
                                    ClipboardStore.shared.updateRunning()
                                } label: { Label(k.title, systemImage: k.symbol) }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("Add").font(.system(size: 12, weight: .semibold))
                        if !hidden.isEmpty {
                            Text("\(hidden.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).background(Capsule().fill(theme.accent))
                        }
                    }
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Capsule().fill(theme.card.opacity(1.8)))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add cards or shortcuts")
            }
            Button {
                withAnimation(IslandModel.openSpring) { model.editing = false }
            } label: {
                Text("Done").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 14).frame(height: 26)
                    .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private func addPill(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(theme.secondary)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().strokeBorder(theme.tertiary, style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])))
        }
        .buttonStyle(PressScaleStyle())
        .help("Add \(title)")
    }
}

// MARK: - Lyrics

struct LyricsLine: View {
    let theme: Theme
    private let lyrics = Lyrics.shared
    private let np = NowPlaying.shared

    var body: some View {
        if np.hasMedia, !lyrics.lines.isEmpty, AppSettings.shared.prefs.lyrics {
            TimelineView(.periodic(from: .now, by: np.isPlaying ? 0.25 : 3600)) { _ in
                let idx = lyrics.index(at: np.elapsed)
                let current = idx.map { lyrics.lines[$0].text } ?? "♪"
                let next = idx.map { $0 + 1 < lyrics.lines.count ? lyrics.lines[$0 + 1].text : "" } ?? lyrics.lines.first?.text ?? ""
                VStack(alignment: .leading, spacing: 1) {
                    Text(current)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppSettings.shared.prefs.musicColors ? Look.shared.musicPrimary : theme.primary)
                        .lineLimit(1)
                    Text(next)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
                .id(idx ?? -1)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: idx)
            }
            .clipped()
        } else if np.hasMedia {
            Text(np.album.isEmpty ? np.artist : np.album)
                .font(.system(size: 11)).foregroundStyle(theme.tertiary).lineLimit(1)
        } else {
            Text(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.tertiary).lineLimit(1)
        }
    }
}

// MARK: - Volume / brightness page

struct SliderPage: View {
    enum Kind { case volume, brightness }
    let theme: Theme
    let kind: Kind
    private let vol = VolumeControl.shared
    private let bri = BrightnessControl.shared

    var body: some View {
        let value = kind == .volume ? Double(vol.volume) : Double(bri.brightness)
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    if kind == .volume { vol.setMuted(!vol.muted) }
                } label: {
                    Image(systemName: symbol(value))
                        .font(.system(size: 18)).foregroundStyle(theme.primary).frame(width: 28)
                        .contentTransition(.symbolEffect(.replace))
                }.buttonStyle(.plain)
                FatSlider(value: value, theme: theme) { v in
                    if kind == .volume { vol.set(Float(v)) } else { bri.set(Float(v)) }
                }
                .frame(height: 22)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(theme.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Text(kind == .volume ? "Output volume" : "Display brightness")
                .font(.system(size: 11)).foregroundStyle(theme.tertiary)
        }
        .padding(.horizontal, 30)
        .frame(maxHeight: .infinity)
    }

    private func symbol(_ v: Double) -> String {
        if kind == .brightness { return v < 0.3 ? "sun.min" : "sun.max" }
        if vol.muted || v == 0 { return "speaker.slash.fill" }
        return v < 0.33 ? "speaker.wave.1.fill" : (v < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }
}

struct FatSlider: View {
    let value: Double
    let theme: Theme
    let onChange: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.card.opacity(1.6))
                Capsule().fill(theme.primary)
                    .frame(width: max(g.size.height, g.size.width * value))
            }
            .scaleEffect(y: dragging ? 1.12 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    onChange(min(max(v.location.x / g.size.width, 0), 1))
                }
                .onEnded { _ in dragging = false })
        }
    }
}
