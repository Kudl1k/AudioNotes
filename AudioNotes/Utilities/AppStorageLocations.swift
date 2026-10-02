import Foundation

/// Cross-platform storage locations for application data, databases, caches, and temporary files.
/// Legacy macOS filesystem/preference migrations are isolated to the macOS platform layer.
enum AppStorageLocations {
    /// Standard cross-platform Application Support directory.
    static var standardApplicationSupport: URL { .applicationSupportDirectory }

    /// Standard cross-platform temporary directory.
    static var temporaryDirectory: URL { FileManager.default.temporaryDirectory }

    /// Standard cross-platform caches directory.
    static var cachesDirectory: URL { .cachesDirectory }

    /// Restores preferences from legacy versions if applicable.
    /// On macOS, checks legacy container preferences. On other platforms, this is a no-op.
    static func restorePreferences(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? "cz.kudladev.AudioNotes",
        defaults: UserDefaults = .standard
    ) {
#if os(macOS)
        MacOSLegacyStorage.restoreLegacyPreferences(home: home, bundleID: bundleID, defaults: defaults)
#endif
    }

    /// Resolves the application support directory.
    /// On macOS, keeps existing sandbox libraries in place when upgrading to the CLI-capable desktop build.
    /// On other platforms, resolves against the standard Application Support directory.
    static func applicationSupport(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? "cz.kudladev.AudioNotes",
        fallback: URL = .applicationSupportDirectory
    ) -> URL {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--performance-fixtures")
            || ProcessInfo.processInfo.arguments.contains("--performance-empty-library") {
            return FileManager.default.temporaryDirectory.appending(path: "AudioNotes-M11-Fixtures", directoryHint: .isDirectory)
        }
#endif
#if os(macOS)
        if let legacy = MacOSLegacyStorage.resolveLegacyApplicationSupport(home: home, bundleID: bundleID) {
            return legacy
        }
#endif
        return fallback
    }
}
