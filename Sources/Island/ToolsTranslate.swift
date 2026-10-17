import AppKit
import SwiftUI
import Observation
#if canImport(Translation)
import Translation
#endif

// MARK: feat/productivity - On-device translation (Apple Translation framework, macOS 15+).
// Text never leaves the Mac: there is no web fallback by design. Language packs are downloaded by
// macOS itself (user-initiated, via the system sheet) and need no entitlement.

struct TranslateView: View {
    let theme: Theme
    var body: some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            OnDeviceTranslateView(theme: theme)
        } else {
            unavailable("On-device translation needs macOS 15 or later.")
        }
        #else
        unavailable("This build does not include Apple's Translation framework.")
        #endif
    }

    private func unavailable(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "character.bubble").font(.system(size: 24)).foregroundStyle(theme.tertiary)
            Text("Translate is not available").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
            Text(msg + " Glance never sends your text to a web service.").font(.system(size: 11)).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
struct OnDeviceTranslateView: View {
    let theme: Theme
    private let prefs = ToolsPrefs.shared
    @State private var input = ""
    @State private var output = ""
    @State private var status = "Type or paste text, then press Translate. Language is detected automatically."
    @State private var languages: [Locale.Language] = []
    @State private var config: TranslationSession.Configuration?
    @State private var needsPack = false
    @State private var preparing = false
    @State private var busy = false
    @FocusState private var focused: Bool

    private var target: Locale.Language { Locale.Language(identifier: prefs.data.translateTarget) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Translate to").font(.system(size: 11)).foregroundStyle(theme.secondary)
                Menu {
                    ForEach(languages, id: \.minimalIdentifier) { l in
                        Button(name(l)) { prefs.data.translateTarget = l.minimalIdentifier }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(name(target)).font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                    }
                    .foregroundStyle(theme.primary).padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(theme.card))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Spacer()
                ToolPill(theme: theme, title: busy ? "Translating" : "Translate", symbol: "arrow.right", prominent: true) { run() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(alignment: .top, spacing: 10) {
                TextEditor(text: $input)
                    .font(.system(size: 12)).foregroundStyle(theme.primary).scrollContentBackground(.hidden).focused($focused)
                    .padding(6).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? theme.accent.opacity(0.7) : .clear, lineWidth: 1.2))
                    .overlay(alignment: .topLeading) {
                        if input.isEmpty { Text("Text to translate").font(.system(size: 12)).foregroundStyle(theme.tertiary).padding(11).allowsHitTesting(false) }
                    }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.opacity(0.7))
                    ScrollView { Text(output).font(.system(size: 12)).foregroundStyle(theme.primary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                    if !output.isEmpty {
                        HStack { Spacer(); Button { copyOutput() } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(theme.secondary) }.buttonStyle(.plain).help("Copy translation") }
                            .padding(8).frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            HStack(spacing: 8) {
                Text(status).font(.system(size: 10)).foregroundStyle(needsPack ? .orange : theme.tertiary).lineLimit(2)
                if needsPack {
                    ToolPill(theme: theme, title: preparing ? "Waiting" : "Download language") { prepare() }
                }
                Spacer()
                Text("On-device only").font(.system(size: 9)).foregroundStyle(theme.tertiary)
            }
        }
        .translationTask(config) { session in
            if preparing {
                do {
                    try await session.prepareTranslation()
                    status = "Language ready. Press Translate."; needsPack = false
                } catch { status = "Download was cancelled or failed." }
                preparing = false
                return
            }
            do {
                let r = try await session.translate(input)
                output = r.targetText
                status = "Detected \(name(r.sourceLanguage)). Translated on this Mac."
            } catch {
                status = "Could not translate: \(error.localizedDescription)"
            }
            busy = false
        }
        .task {
            languages = await LanguageAvailability().supportedLanguages
                .sorted { name($0).localizedCompare(name($1)) == .orderedAscending }
            focused = true
        }
    }

    private func name(_ l: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: l.minimalIdentifier) ?? l.minimalIdentifier
    }

    private func run() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        needsPack = false
        Task {
            let avail = LanguageAvailability()
            let st = try? await avail.status(for: text, to: target)
            switch st {
            case .installed:
                status = "Translating on this Mac"
                trigger()
            case .supported:
                busy = false
                needsPack = true
                status = "This language pair needs a one-time download. macOS shows its own sheet; the translation still runs on this Mac."
            case .unsupported:
                busy = false
                status = "That language pair is not supported on-device."
            default:
                busy = false
                status = "Could not detect the language of that text."
            }
        }
    }

    private func prepare() {
        preparing = true
        status = "Waiting for macOS to download the language..."
        trigger()
    }

    private func trigger() {
        if config == nil { config = TranslationSession.Configuration(source: nil, target: target) }
        else { config?.target = target; config?.invalidate() }
    }

    private func copyOutput() {
        let pb = Env.pasteboard
        pb.clearContents()
        pb.setString(output, forType: .string)
        ClipboardStore.shared.noteOwnWrite()
    }
}
#endif
