import Foundation

enum AppStorageLocations {
    static func restorePreferences(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   bundleID: String = Bundle.main.bundleIdentifier ?? "cz.kudladev.AudioNotes",
                                   defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: "storage.desktopPreferencesRestored") else { return }
        defer { defaults.set(true, forKey: "storage.desktopPreferencesRestored") }
        var candidates = [home.appending(path: "Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")]
        if bundleID == "cz.stepankudlacek.audionotes" {
            candidates += [home.appending(path: "Library/Preferences/cz.kudladev.AudioNotes.plist"),
                           home.appending(path: "Library/Containers/cz.kudladev.AudioNotes/Data/Library/Preferences/cz.kudladev.AudioNotes.plist")]
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            // Only known non-secret namespaces; existing choices win.
            for (key, value) in values where key.hasPrefix("llm.") || key.hasPrefix("transcription.") || key.hasPrefix("ai.") {
                guard defaults.object(forKey: key) == nil,
                      !["key", "token", "secret", "credential", "password"].contains(where: { key.lowercased().contains($0) }) else { continue }
                defaults.set(value, forKey: key)
            }
        }
    }

    /// Keep the existing sandbox library in place when upgrading to the CLI-capable
    /// desktop build. No recordings, database records, or model files are moved.
    static func applicationSupport(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   bundleID: String = Bundle.main.bundleIdentifier ?? "cz.kudladev.AudioNotes",
                                   fallback: URL = .applicationSupportDirectory) -> URL {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--performance-fixtures") || ProcessInfo.processInfo.arguments.contains("--performance-empty-library") {
            return FileManager.default.temporaryDirectory.appending(path: "AudioNotes-M11-Fixtures", directoryHint: .isDirectory)
        }
#endif
        let ids = bundleID == "cz.stepankudlacek.audionotes" ? ["cz.kudladev.AudioNotes", bundleID] : [bundleID]
        for id in ids {
            let legacy = home.appending(path: "Library/Containers/\(id)/Data/Library/Application Support")
            if FileManager.default.fileExists(atPath: legacy.appending(path: "default.store").path)
                || FileManager.default.fileExists(atPath: legacy.appending(path: "AudioNotes").path) { return legacy }
        }
        return fallback
    }
}
