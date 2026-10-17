import SwiftUI

// MARK: feat/prompter: Settings section (referenced by one line in SettingsView.swift)

struct PrompterSettingsSection: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Section("Prompter") {
            Picker("Speed", selection: $settings.prefs.prompterSpeed) {
                ForEach(PrompterSpeed.allCases) { s in Text("\(s.title) \(Int(s.ptPerSecond))").tag(s) }
            }.pickerStyle(.segmented)
            Text("Points a second. While it runs, the trackpad or scroll wheel moves the text by hand, and so do the arrow keys.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Countdown", selection: $settings.prefs.prompterCountdown) {
                Text("Off").tag(PrompterCountdown.off); Text("3-2-1").tag(PrompterCountdown.three)
                Text("5 s").tag(PrompterCountdown.five); Text("10 s").tag(PrompterCountdown.ten)
            }.pickerStyle(.segmented)
            Picker("Text size", selection: $settings.prefs.prompterSize) {
                Text("S").tag(PrompterSize.s); Text("M").tag(PrompterSize.m); Text("L").tag(PrompterSize.l)
            }.pickerStyle(.segmented)
            Picker("Text colour", selection: $settings.prefs.prompterColour) {
                ForEach(PrompterColour.allCases, id: \.self) { c in Text(c.title).tag(c.rawValue) }
            }.pickerStyle(.segmented)
            HStack {
                Text("Box width")
                Slider(value: $settings.prefs.prompterWidth, in: 360...800, step: 10)
                Text("\(Int(settings.prefs.prompterWidth)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            HStack {
                Text("Box height")
                Slider(value: $settings.prefs.prompterHeight, in: 120...420, step: 10)
                Text("\(Int(settings.prefs.prompterHeight)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            Toggle("Mirror the text (for beam-splitter glass)", isOn: $settings.prefs.prompterMirror)

            Toggle("Hide from screen sharing and recording", isOn: $settings.prefs.prompterHideFromSharing)
            Text("Glance asks macOS to leave the prompter window out of screen sharing, screenshots and recordings, so people on a call see your screen without your script. A few capture apps ignore this request, so do a quick test recording before an important call.")
                .font(.caption).foregroundStyle(.secondary)
            if !settings.prefs.prompterHideFromSharing {
                Text("Your audience may see the prompter while you share your screen.").font(.caption).foregroundStyle(.orange)
            }

            Picker("Voice follow", selection: $settings.prefs.prompterVoice) {
                Text("Off").tag(PrompterVoice.off)
                Text("Basic (scrolls while you speak)").tag(PrompterVoice.basic)
                Text("Smart (follows your words)").tag(PrompterVoice.smart)
            }
            Text("Basic listens only to how loud you are: it scrolls while you speak and pauses when you stop. Smart also recognises your words on this Mac and keeps your place, even if you skip or repeat a sentence. Glance asks for the microphone (and Speech Recognition for Smart) the first time you start the prompter with voice follow on. Audio is never recorded, saved or sent anywhere.")
                .font(.caption).foregroundStyle(.secondary)
            Text("While it runs: click or Space to pause, hover to hold, Esc to stop.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: settings.prefs.prompterLook) { _, _ in Prompter.shared.restyle() }
    }
}

extension Prefs {
    /// Everything that changes how the running box looks; changing any of it rebuilds the box in place.
    var prompterLook: String {
        "\(prompterSize.rawValue)|\(prompterColour)|\(prompterWidth)|\(prompterHeight)|\(prompterMirror)|\(prompterHideFromSharing)"
    }
}
