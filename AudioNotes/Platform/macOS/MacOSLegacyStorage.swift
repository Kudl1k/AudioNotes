import Foundation

#if os(macOS)
/// Keeps existing libraries in place; product branding never determines their folder names.
enum MacOSLegacyStorage {
    private static let currentID = "cz.kudladev.soniquill"
    private static let previousID = "cz.stepankudlacek.audionotes"
    private static let developmentID = "cz.kudladev.AudioNotes"

    private static func storageIDs(for bundleID: String) -> [String] {
        switch bundleID {
        case currentID: [developmentID, previousID, currentID]
        case previousID: [developmentID, previousID]
        default: [bundleID]
        }
    }

    static func resolveLegacyApplicationSupport(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? currentID
    ) -> URL? {
        for id in storageIDs(for: bundleID) {
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
        bundleID: String = Bundle.main.bundleIdentifier ?? currentID,
        defaults: UserDefaults = .standard
    ) {
        // Independent from the old migration marker, which may already be set in an old domain.
        let marker = bundleID == currentID ? "storage.soniquillPreferencesRestored.v1" : "storage.desktopPreferencesRestored"
        guard !defaults.bool(forKey: marker) else { return }
        defer { defaults.set(true, forKey: marker) }
        let ids = bundleID == currentID ? [previousID, developmentID] : storageIDs(for: bundleID).reversed().map { $0 }
        var candidates: [URL] = []
        for id in ids {
            if bundleID == currentID || id != bundleID {
                candidates.append(home.appending(path: "Library/Preferences/\(id).plist"))
            }
            candidates.append(home.appending(path: "Library/Containers/\(id)/Data/Library/Preferences/\(id).plist"))
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            for (key, value) in values where isCompatiblePreference(key) {
                // Existing choices win. Never copy secrets from a legacy defaults file.
                guard defaults.object(forKey: key) == nil,
                      !isSecretPreference(key) else { continue }
                defaults.set(value, forKey: key)
            }
        }
    }

    private static func isSecretPreference(_ key: String) -> Bool {
        // max_tokens is a non-secret generation ceiling, not an authentication token.
        if key.hasSuffix(".max_tokens") { return false }
        return ["key", "token", "secret", "credential", "password"].contains { key.lowercased().contains($0) }
    }

    private static func isCompatiblePreference(_ key: String) -> Bool {
        let namespaces = ["llm.", "transcription.", "ai."]
        let exactKeys: Set<String> = [
            "libraryShowsCost", "onboarding.completed.v1", "chatgpt.account.session", "chatgpt.ext_agent_host_id",
            "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUSendProfileInfo", "SULastCheckTime"
        ]
        return namespaces.contains(where: key.hasPrefix) || exactKeys.contains(key)
    }
}
#endif
