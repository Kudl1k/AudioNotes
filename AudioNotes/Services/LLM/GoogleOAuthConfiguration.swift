import Foundation

/// Developer-owned Desktop OAuth client JSON. Never sourced from user preferences.
struct GoogleOAuthConfiguration: Sendable {
    let clientID: String
    let projectID: String
    let clientSecret: String?

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "GoogleOAuth", withExtension: "json") else {
            throw GoogleOAuthConfigurationError.missingFile
        }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> Self {
        guard let data = try? Data(contentsOf: url) else {
            throw GoogleOAuthConfigurationError.unreadableFile
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Self {
        struct DesktopClient: Decodable {
            let client_id: String
            let project_id: String
            let client_secret: String?
        }
        struct Document: Decodable { let installed: DesktopClient }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            throw GoogleOAuthConfigurationError.invalidFile
        }
        let clientID = document.installed.client_id.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectID = document.installed.project_id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !projectID.isEmpty else {
            throw GoogleOAuthConfigurationError.invalidFile
        }
        let secret = document.installed.client_secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(clientID: clientID, projectID: projectID, clientSecret: secret?.isEmpty == false ? secret : nil)
    }
}

enum GoogleOAuthConfigurationError: LocalizedError, Equatable {
    case missingFile
    case unreadableFile
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .missingFile: "Google sign-in is unavailable: this build does not include GoogleOAuth.json."
        case .unreadableFile: "Google sign-in is unavailable: the app’s OAuth configuration could not be read."
        case .invalidFile: "Google sign-in is unavailable: the app’s OAuth configuration must contain a Desktop client ID and project ID."
        }
    }
}
