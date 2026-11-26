import Foundation

/// Non-secret, device-local Drive sharing state (folder selections, project links, sync baselines,
/// reserved file IDs and pairings). Everything lives under one `UserDefaults` prefix so that
/// disconnecting Google Drive can forget it without touching unrelated preferences or Keychain items.
enum DriveSharingLocalState {
    static let keyPrefix = "drive.project."

    static func reset(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
