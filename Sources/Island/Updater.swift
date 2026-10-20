import AppKit
import Sparkle
import SwiftUI

/// In-app updates with Sparkle 2: "A new version of Glance is available", release notes,
/// Install and Relaunch. The feed (SUFeedURL) and the EdDSA public key (SUPublicEDKey) are in
/// Info.plist; every update zip must be signed with the matching private key (kept in the
/// release Mac's Keychain, never in the repo), so a changed or forged download is refused.
///
/// Glance is a menu bar app with no Dock icon, so a daily background check never pops a window
/// over your work: it shows a peek with a View button instead (Sparkle "gentle reminders").
///
/// Test override (never needed in normal use): `GLANCE_UPDATE_FEED=<url>` in the environment, or
/// `defaults write <bundle id> GlanceUpdateFeedURL <url>`. Only https, or http to this Mac
/// (localhost / 127.0.0.1), is accepted. The signature check still applies to the override.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?
    /// Version found by the last check that has not been installed yet (shown in Settings).
    private(set) var pendingVersion: String?

    var updater: SPUUpdater? { controller?.updater }
    var available: Bool { controller != nil }
    var canCheck: Bool { updater?.canCheckForUpdates ?? false }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { updater?.lastUpdateCheckDate }

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    func start() {
        guard controller == nil else { return }
        // `swift run` or an app built without the feed keys: no updater rather than a broken one.
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            NSLog("Glance updates: not configured in Info.plist, updater off")
            return
        }
        // Isolated test instances only check a feed they were pointed at.
        if Env.isolated && Self.feedOverride == nil { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        if let o = Self.feedOverride { NSLog("Glance updates: test feed %@", o) }
    }

    /// "Check for Updates…" (menu bar, Settings, command palette).
    func checkForUpdates() {
        guard let controller else { return }
        IslandModel.shared.setExpanded(false)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: Feed override (testing)

    nonisolated static var feedOverride: String? {
        let raw = ProcessInfo.processInfo.environment["GLANCE_UPDATE_FEED"]
            ?? UserDefaults.standard.string(forKey: "GlanceUpdateFeedURL")
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
              let u = URL(string: s), let scheme = u.scheme?.lowercased() else { return nil }
        if scheme == "https" { return s }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(u.host ?? "") { return s }
        NSLog("Glance updates: ignoring test feed %@ (https or localhost only)", s)
        return nil
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? { Self.feedOverride }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        pendingVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { pendingVersion = nil }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders for a menu bar app)

    // This protocol is not main-actor annotated; Sparkle calls it on the main thread.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Right after launch Sparkle may show it in focus; otherwise Glance shows a peek first.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            pendingVersion = version
            guard !handleShowingUpdate, !userInitiated else { return }
            IslandModel.shared.enqueue(Peek(symbol: "arrow.down.circle.fill", title: "Update available",
                                            subtitle: "Glance \(version)", tint: .green, duration: 12,
                                            actionTitle: "View", action: { Updater.shared.checkForUpdates() }))
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {}
}

// MARK: - Settings › Updates

struct UpdateSettingsSection: View {
    private let updater = Updater.shared
    @State private var autoCheck = Updater.shared.automaticallyChecks
    @State private var tick = 0   // refreshes "Last checked" after a check

    var body: some View {
        Section("Updates") {
            LabeledContent("Version", value: Updater.currentVersion)
            if updater.available {
                Toggle("Automatically check for updates (daily)", isOn: Binding(get: { autoCheck }, set: { on in
                    updater.automaticallyChecks = on
                    autoCheck = updater.automaticallyChecks
                }))
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary).id(tick)
                    Spacer()
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                        Task { try? await Task.sleep(for: .seconds(3)); tick += 1 }
                    }
                }
            } else {
                Text("In-app updates are not set up in this build.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { autoCheck = updater.automaticallyChecks; tick += 1 }
    }

    private var status: String {
        if let v = updater.pendingVersion, v != Updater.currentVersion { return "Glance \(v) is available." }
        guard let d = updater.lastCheck else { return "Not checked yet." }
        return "Last checked " + d.formatted(.relative(presentation: .named))
    }
}
