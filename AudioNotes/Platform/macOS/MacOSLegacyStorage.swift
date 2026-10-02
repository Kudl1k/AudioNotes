import Foundation

#if os(macOS)
/// Isolates legacy macOS sandbox container locations and preference restoration.
/// Shared application code must not depend on legacy macOS container paths or desktop plist files.
enum MacOSLegacyStorage {
    static func resolveLegacyApplicationSupport(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? "cz.kudladev.AudioNotes"
    ) -> URL? {
        let ids = bundleID == "cz.stepankudlacek.audionotes" ? ["cz.kudladev.AudioNotes", bundleID] : [bundleID]
        for id in ids {
            let legacy = home.appending(path: "Library/Containers/\(id)/Data/Library/Application Support")
            if FileManager.default.fileExists(atPath: legacy.appending(path: "default.store").path)
                || FileManager.default.fileExists(atPath: legacy.appending(path: "AudioNotes").path) {
                return legacy
            }
        }
        return nil
    }

    static func restoreLegacyPreferences(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? "cz.kudladev.AudioNotes",
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: "storage.desktopPreferencesRestored") else { return }
        defer { defaults.set(true, forKey: "storage.desktopPreferencesRestored") }
        var candidates = [home.appending(path: "Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")]
        if bundleID == "cz.stepankudlacek.audionotes" {
            candidates += [
                home.appending(path: "Library/Preferences/cz.kudladev.AudioNotes.plist"),
                home.appending(path: "Library/Containers/cz.kudladev.AudioNotes/Data/Library/Preferences/cz.kudladev.AudioNotes.plist")
            ]
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
}
#endif
