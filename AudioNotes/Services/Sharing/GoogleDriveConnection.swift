import Foundation

enum GoogleDriveSharingError: LocalizedError, Equatable {
    case configuration, localOnly, signInRequired, consent, invalidResponse, http(Int), busy, changedFile

    var errorDescription: String? {
        switch self {
        case .configuration: "Google Drive is unavailable in this build. A separate Drive OAuth project and client must be configured."
        case .localOnly: "Google Drive is unavailable while Local Only is enabled."
        case .signInRequired: "Connect Google Drive again to continue."
        case .consent: "Google Drive authorization did not grant the required file access."
        case .invalidResponse: "Google Drive returned an unexpected response."
        case .http(let status): "Google Drive rejected the request (HTTP \(status))."
        case .busy: "Another Google Drive operation is in progress."
        case .changedFile: "The upload no longer matches the prepared package."
        }
    }
}

enum DriveSharingPrivacy {
    static let check: @Sendable () throws -> Void = {
        guard !UserDefaults.standard.bool(forKey: "ai.localOnly") else { throw GoogleDriveSharingError.localOnly }
        try Task.checkCancellation()
    }
}

struct DriveHTTPTransport: Sendable {
    let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let live: Self = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        return Self { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GoogleDriveSharingError.invalidResponse }
            return (data, http)
        }
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

actor GoogleDriveConnection {
    static let shared = GoogleDriveConnection()
    static let scope = "https://www.googleapis.com/auth/drive.file"
    private let storage: any GoogleOAuthCredentialStoring
    private let transport: DriveHTTPTransport
    private let configuration: @Sendable () throws -> GoogleOAuthConfiguration
    private let checkPrivacy: @Sendable () throws -> Void
    private var isBusy = false
    private var connectionID = UUID()

    init(storage: any GoogleOAuthCredentialStoring = GoogleOAuthKeychainStore(
            service: "cz.kudladev.soniquill.drive-oauth", clientSecretAccount: "google-drive-desktop-client-secret"),
         transport: DriveHTTPTransport = .live,
         configuration: @escaping @Sendable () throws -> GoogleOAuthConfiguration = { try GoogleDriveConnection.client() },
         checkPrivacy: @escaping @Sendable () throws -> Void = DriveSharingPrivacy.check) {
        self.storage = storage
        self.transport = transport
        self.configuration = configuration
        self.checkPrivacy = checkPrivacy
    }

    nonisolated static func client(bundle: Bundle = .main) throws -> GoogleOAuthConfiguration {
#if os(iOS)
        guard bundle.bundleIdentifier == "cz.kudladev.soniquill",
              let clientID = bundle.object(forInfoDictionaryKey: "DriveOAuthClientID") as? String,
              clientID.hasSuffix(".apps.googleusercontent.com"),
              let projectID = bundle.object(forInfoDictionaryKey: "DriveCloudProjectID") as? String,
              !projectID.isEmpty,
              let scheme = bundle.object(forInfoDictionaryKey: "DriveOAuthURLScheme") as? String,
              scheme == clientID.split(separator: ".").reversed().joined(separator: "."),
              let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true }),
              projectID != bundle.object(forInfoDictionaryKey: "GoogleCloudProjectID") as? String else {
            throw GoogleDriveSharingError.configuration
        }
        return .init(clientID: clientID, projectID: projectID, clientSecret: nil, redirectScheme: scheme)
#else
        guard let clientID = bundle.object(forInfoDictionaryKey: "DriveOAuthClientID") as? String,
              clientID.hasSuffix(".apps.googleusercontent.com"),
              let projectID = bundle.object(forInfoDictionaryKey: "DriveCloudProjectID") as? String,
              !projectID.isEmpty, projectID != "sublime-elixir-474816-b4" else {
            throw GoogleDriveSharingError.configuration
        }
        if let gemini = try? GoogleOAuthConfiguration.load(bundle: bundle),
           projectID == gemini.projectID || clientID == gemini.clientID {
            throw GoogleDriveSharingError.configuration
        }
        return .init(clientID: clientID, projectID: projectID, clientSecret: nil)
#endif
    }

    func status() async throws -> Bool {
        _ = try configuration()
        return try await storage.load() != nil
    }

    func connect() async throws {
        _ = try await authorize(pickFolder: false)
    }

    func chooseFolder() async throws -> DriveProjectFolder {
        guard let folder = try await authorize(pickFolder: true) else { throw GoogleDriveSharingError.consent }
        return folder
    }

    private func authorize(pickFolder: Bool) async throws -> DriveProjectFolder? {
        try checkPrivacy()
        guard !isBusy else { throw GoogleDriveSharingError.busy }
        isBusy = true
        defer { isBusy = false }
        let client = try configuration()
        let state = try PKCEHelper.generateRandomToken()
        let verifier = try PKCEHelper.generateCodeVerifier()
#if os(iOS)
        guard let scheme = client.redirectScheme else { throw GoogleDriveSharingError.configuration }
        let redirect = scheme + ":/oauth2redirect"
#else
        let listener = ChatGPTLoopbackListener()
        let (address, _) = try await listener.start()
        defer { listener.cancel() }
        let redirect = address.replacingOccurrences(of: "/auth/callback", with: "")
#endif
        var authURL = try GoogleGeminiOAuthService.authorizationURL(
            clientID: client.clientID, redirectURI: redirect, state: state,
            challenge: PKCEHelper.generateCodeChallenge(from: verifier), scopes: [Self.scope])
        if pickFolder {
            var address = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
            address.queryItems?.append(contentsOf: [
                .init(name: "trigger_onepick", value: "true"),
                .init(name: "allow_folder_selection", value: "true"),
                .init(name: "mimetypes", value: DriveProjectRemote.folderType)
            ])
            authURL = address.url!
        }
        try checkPrivacy()
        let callback: ChatGPTCallbackResult
#if os(iOS)
        let callbackURL = try await GoogleOAuthAuthenticationSession.authenticate(url: authURL, callbackScheme: scheme)
        guard let address = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              address.scheme == scheme, address.host == nil, address.path == "/oauth2redirect" else {
            throw GoogleDriveSharingError.consent
        }
        callback = GoogleGeminiOAuthService.callbackResult(from: callbackURL)
#else
        guard await SystemBrowserOpener().open(authURL) else { throw GoogleDriveSharingError.consent }
        callback = try await listener.waitForCallback(timeout: 300)
#endif
        guard callback.state == state, callback.error == nil, let code = callback.code else {
            throw GoogleDriveSharingError.consent
        }
        let pickedID = callback.pickedFileIDs
        if pickFolder {
            guard let pickedID, DriveProjectRemote.validID(pickedID) else { throw GoogleDriveSharingError.consent }
        }
        let tokens = try await token([
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier, "redirect_uri": redirect
        ], client: client, requireScope: true)
        guard let refresh = tokens.refresh_token, !refresh.isEmpty else { throw GoogleDriveSharingError.consent }
        try checkPrivacy()
        var folder: DriveProjectFolder?
        if pickFolder, let pickedID {
            let remote = DriveProjectRemote(transport: transport, checkPrivacy: checkPrivacy,
                                            token: { _ in tokens.access_token })
            folder = try await remote.validateFolder(id: pickedID)
        }
        try checkPrivacy()
        try await storage.save(credential(tokens, refresh: refresh))
        connectionID = UUID()
        return folder
    }

    func uploadToken() async throws -> GoogleDriveUpload.Token {
        try checkPrivacy()
        let id = connectionID
        _ = try await accessToken(connection: id, rejected: nil)
        return { rejected in try await self.accessToken(connection: id, rejected: rejected) }
    }

    private func accessToken(connection: UUID, rejected: String?) async throws -> String {
        guard connection == connectionID else { throw GoogleDriveSharingError.signInRequired }
        try checkPrivacy()
        guard !isBusy else { throw GoogleDriveSharingError.busy }
        isBusy = true
        defer { isBusy = false }
        let client = try configuration()
        guard let previous = try await storage.load() else { throw GoogleDriveSharingError.signInRequired }
        if previous.accessToken != rejected, previous.expiresAt.timeIntervalSinceNow > 60 {
            return previous.accessToken
        }
        let updated = try await token(["grant_type": "refresh_token", "refresh_token": previous.refreshToken],
                                      client: client, requireScope: false)
        try await storage.save(credential(updated, refresh: updated.refresh_token ?? previous.refreshToken))
        try checkPrivacy()
        return updated.access_token
    }

    /// Always offers local disconnect, including while Local Only is enabled.
    func disconnect() async throws {
        guard !isBusy else { throw GoogleDriveSharingError.busy }
        isBusy = true
        defer { isBusy = false }
        let stored = try await storage.load()
        try await storage.delete()
        connectionID = UUID()
        guard let stored, (try? configuration()) != nil, (try? checkPrivacy()) != nil else { return }
        let request = formRequest(path: "revoke", parameters: ["token": stored.refreshToken])
        let (_, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw GoogleDriveSharingError.http(response.statusCode) }
    }

    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let scope: String?
    }

    private func token(_ parameters: [String: String], client: GoogleOAuthConfiguration,
                       requireScope: Bool) async throws -> Tokens {
        try checkPrivacy()
        let secret: String?
#if os(macOS)
        if let clientSecret = client.clientSecret {
            secret = clientSecret
        } else {
            secret = try await (storage as? any GoogleOAuthClientSecretStoring)?.loadClientSecret()
        }
#else
        secret = nil
#endif
        try checkPrivacy()
        var fields = GoogleGeminiOAuthService.tokenParameters(parameters, clientSecret: secret)
        fields["client_id"] = client.clientID
        let (data, response) = try await transport.send(formRequest(path: "token", parameters: fields))
        if response.statusCode == 400, !requireScope,
           (try? JSONDecoder().decode([String: String].self, from: data))?["error"] == "invalid_grant" {
            try await storage.delete()
            connectionID = UUID()
            throw GoogleDriveSharingError.signInRequired
        }
        guard response.statusCode == 200 else { throw GoogleDriveSharingError.http(response.statusCode) }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        let scopes = tokens.scope?.split(separator: " ").map(String.init)
        guard scopes.map({ Set($0) == [Self.scope] }) ?? !requireScope,
              !tokens.access_token.isEmpty, tokens.expires_in > 0 else {
            throw GoogleDriveSharingError.consent
        }
        return tokens
    }

    private func credential(_ tokens: Tokens, refresh: String) -> GoogleOAuthCredential {
        .init(accessToken: tokens.access_token, refreshToken: refresh,
              expiresAt: Date().addingTimeInterval(Double(tokens.expires_in)), email: nil)
    }

    private func formRequest(path: String, parameters: [String: String]) -> URLRequest {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ field: String) -> String { field.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(parameters.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&").utf8)
        return request
    }
}
