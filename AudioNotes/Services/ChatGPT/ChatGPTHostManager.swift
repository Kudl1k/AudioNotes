import Foundation

/// Manages a stable, opaque host identifier (`ext_agent_host_id`) for this installation.
///
/// Follows OpenAI Sign in with ChatGPT open-source token sharing specifications:
/// Uses the `urn:uuid:<UUIDv4>` format, generated once per installation and stored locally.
enum ChatGPTHostManager {
    private static let hostIDKey = "chatgpt.ext_agent_host_id"

    static func hostID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: hostIDKey), !existing.isEmpty {
            return existing
        }
        let newID = "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(newID, forKey: hostIDKey)
        return newID
    }
}
