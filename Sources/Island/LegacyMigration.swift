import Foundation

/// One-time move from the app's pre-release identity to Glance.
///
/// Before it was called Glance, the app was built with the bundle id `local.aryan.island` and kept
/// its data in `~/Library/Application Support/Island`. On the first launch of Glance, if that old
/// data exists and Glance has none of its own yet, it is copied across: settings, Shelf, clipboard
/// history, notes, prompter scripts, keep-awake state and so on.
///
/// Rules: copy only, never delete or change the old data; run only when the new location is empty;
/// never run in isolated test mode. A fresh install with no old data does nothing.
enum LegacyMigration {
    static let legacyBundleID = "local.aryan.island"
    static let legacySupportFolder = "Island"
    private static let markerKey = "GlanceLegacyMigration"

    static func run() {
        guard !Env.isolated, let newID = Bundle.main.bundleIdentifier, newID != legacyBundleID else { return }
        migrateDefaults(newID: newID)
        migrateSupportFolder()
    }

    /// Copies the old UserDefaults domain into Glance's domain when Glance's domain is empty.
    private static func migrateDefaults(newID: String) {
        let ud = UserDefaults.standard
        let current = ud.persistentDomain(forName: newID) ?? [:]
        guard current.isEmpty,
              let old = ud.persistentDomain(forName: legacyBundleID), !old.isEmpty else { return }
        var copy = old
        copy[markerKey] = "copied \(old.count) keys from \(legacyBundleID) on \(ISO8601DateFormatter().string(from: Date()))"
        ud.setPersistentDomain(copy, forName: newID)
        NSLog("Glance: copied %d settings from the previous app (%@). The old settings were left in place.", old.count, legacyBundleID)
    }

    /// Copies ~/Library/Application Support/Island into Glance's folder when Glance has no folder yet.
    /// Sockets (the old app's live socket) are skipped; everything else is copied as is.
    private static func migrateSupportFolder() {
        let fm = FileManager.default
        let newDir = Env.supportDir
        let oldDir = newDir.deletingLastPathComponent().appendingPathComponent(legacySupportFolder, isDirectory: true)
        var isDir: ObjCBool = false
        guard oldDir.standardizedFileURL != newDir.standardizedFileURL,
              fm.fileExists(atPath: oldDir.path, isDirectory: &isDir), isDir.boolValue,
              !fm.fileExists(atPath: newDir.path) else { return }
        do {
            try fm.createDirectory(at: newDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            NSLog("Glance: could not create %@ for migration: %@", newDir.path, String(describing: error))
            return
        }
        let items = (try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: [.fileResourceTypeKey], options: [])) ?? []
        var copied = 0, skipped = 0
        for src in items {
            let type = (try? src.resourceValues(forKeys: [.fileResourceTypeKey]))?.fileResourceType
            if type == .socket || type == .unknown { skipped += 1; continue }
            do {
                try fm.copyItem(at: src, to: newDir.appendingPathComponent(src.lastPathComponent))
                copied += 1
            } catch {
                skipped += 1
                NSLog("Glance: migration skipped %@: %@", src.lastPathComponent, String(describing: error))
            }
        }
        NSLog("Glance: copied %d items from %@ (%d skipped). The old folder was left in place.", copied, oldDir.path, skipped)
    }
}
