import Foundation

/// Developer-owned Desktop OAuth client JSON. Never sourced from user preferences.
struct GoogleOAuthConfiguration: Sendable {
    let clientID: String
    let projectID: String
    let clientSecret: String?
    let redirectScheme: String?

    init(clientID: String, projectID: String, clientSecret: String?, redirectScheme: String? = nil) {
        self.clientID = clientID
        self.projectID = projectID
        self.clientSecret = clientSecret
        self.redirectScheme = redirectScheme
    }

    static func load(bundle: Bundle = .main) throws -> Self {
#if os(iOS)
        guard let configuredBundleID = bundle.object(forInfoDictionaryKey: "GoogleOAuthClientBundleIdentifier") as? String,
              configuredBundleID == bundle.bundleIdentifier else {
            throw GoogleOAuthConfigurationError.iOSBundleMismatch
        }
        guard let clientID = bundle.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String,
              let redirectScheme = bundle.object(forInfoDictionaryKey: "GoogleOAuthURLScheme") as? String,
              let projectID = bundle.object(forInfoDictionaryKey: "GoogleCloudProjectID") as? String,
              !clientID.isEmpty, !redirectScheme.isEmpty, !projectID.isEmpty else {
            throw GoogleOAuthConfigurationError.missingIOSClient
        }
        guard redirectScheme == "com.googleusercontent.apps." + String(clientID.split(separator: ".").first ?? "") else {
            throw GoogleOAuthConfigurationError.invalidIOSClient
        }
        return Self(clientID: clientID, projectID: projectID, clientSecret: nil, redirectScheme: redirectScheme)
#else
        guard let url = bundle.url(forResource: "GoogleOAuth", withExtension: "json") else {
            throw GoogleOAuthConfigurationError.missingFile
        }
        return try load(from: url)
#endif
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
    case iOSBundleMismatch
    case missingIOSClient
    case invalidIOSClient
    case unreadableFile
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .iOSBundleMismatch: "Google sign-in is unavailable until the developer configures an iOS OAuth client for Soniquill’s bundle identifier. API-key authentication remains available."
        case .missingIOSClient: "Google sign-in is unavailable on iOS until its OAuth client, callback URL scheme, and Google Cloud project are configured."
        case .invalidIOSClient: "Google sign-in is unavailable: the iOS callback scheme does not match the configured client ID."
        case .missingFile: "Google sign-in is unavailable: this build does not include GoogleOAuth.json."
        case .unreadableFile: "Google sign-in is unavailable: the app’s OAuth configuration could not be read."
        case .invalidFile: "Google sign-in is unavailable: the app’s OAuth configuration must contain a Desktop client ID and project ID."
        }
    }
}
