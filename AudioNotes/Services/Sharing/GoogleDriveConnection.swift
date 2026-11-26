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

    static let live: Self = direct.retrying()

    private static let direct: Self = {
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

    /// Retries transient Drive/OAuth failures with bounded backoff. Requests are `Data`-bodied and therefore
    /// re-sendable; resumable chunk PUTs are never replayed here because the protocol requires a status query
    /// first (`GoogleDriveUpload` handles that). Status probes (`bytes */N`) carry no body and are retried.
    func retrying(_ policy: DriveRetryPolicy = .standard) -> Self {
        let base = self
        return Self { request in
            var attempt = 0
            while true {
                try Task.checkCancellation()
                let (data, response) = try await base.send(request)
                guard attempt < policy.maxRetries, Self.isReplayable(request),
                      DriveRetryPolicy.isTransient(response, body: data) else {
                    return (data, response)
                }
                try await policy.sleep(policy.delay(attempt: attempt, retryAfter: response))
                attempt += 1
            }
        }
    }

    static func isReplayable(_ request: URLRequest) -> Bool {
        guard request.httpMethod == "PUT" else { return true }
        return request.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes */") == true
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

struct DriveRetryPolicy: Sendable {
    var maxRetries = 3
    var baseDelay: Duration = .milliseconds(500)
    var maxRetryAfter: Duration = .seconds(30)
    /// Multiplier applied to the exponential delay; injectable so tests are deterministic.
    var jitter: @Sendable () -> Double = { Double.random(in: 0.75...1.25) }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    static let standard = Self()

    func delay(attempt: Int, retryAfter response: HTTPURLResponse?) -> Duration {
        if let value = response?.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
           let seconds = Int(value), seconds >= 0 {
            return min(.seconds(seconds), maxRetryAfter)
        }
        let exponential = baseDelay * (1 << min(attempt, 16))
        return min(exponential * max(0, jitter()), maxRetryAfter)
    }

    static func isTransient(_ response: HTTPURLResponse, body: Data) -> Bool {
        switch response.statusCode {
        case 429, 500, 502, 503, 504: return true
        case 403: return isRateLimit(body)
        default: return false
        }
    }

    static func isRateLimit(_ body: Data) -> Bool {
        struct Envelope: Decodable {
            struct Failure: Decodable {
                struct Detail: Decodable { let reason: String? }
                let errors: [Detail]?
            }
            let error: Failure?
        }
        guard let failure = (try? JSONDecoder().decode(Envelope.self, from: body))?.error else { return false }
        let reasons = Set((failure.errors ?? []).compactMap(\.reason))
        return !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded"])
    }
}

actor GoogleDriveConnection {
    static let shared = GoogleDriveConnection()
    static let scope = "https://www.googleapis.com/auth/drive.file"
    private let storage: any GoogleOAuthCredentialStoring
    private let transport: DriveHTTPTransport
    private let configuration: @Sendable () throws -> GoogleOAuthConfiguration
    private let checkPrivacy: @Sendable () throws -> Void
    private let resetLocalState: @MainActor @Sendable () -> Void
    private let makeListener: @Sendable () -> any ChatGPTLoopbackListening
    private let openBrowser: @Sendable (URL) async -> Bool
    /// Only one browser authorization may run at a time; token reads never wait on it.
    private var isAuthorizing = false
    private var isDisconnecting = false
    /// A single in-flight refresh that concurrent token callers share.
    private var refresh: (id: UUID, task: Task<String, Error>)?
    /// Bound into `uploadToken()` closures. Changes only when the stored grant is removed
    /// (disconnect or `invalid_grant`), so re-authorizing keeps running work alive.
    private var connectionID = UUID()
    /// Changes whenever the stored credential is replaced or removed, so a refresh that started
    /// against an older credential never overwrites the newer one.
    private var credentialGeneration = 0

    init(storage: any GoogleOAuthCredentialStoring = GoogleOAuthKeychainStore(
            service: "cz.kudladev.soniquill.drive-oauth", clientSecretAccount: "google-drive-desktop-client-secret"),
         transport: DriveHTTPTransport = .live,
         configuration: @escaping @Sendable () throws -> GoogleOAuthConfiguration = { try GoogleDriveConnection.client() },
         checkPrivacy: @escaping @Sendable () throws -> Void = DriveSharingPrivacy.check,
         resetLocalState: @escaping @MainActor @Sendable () -> Void = { DriveSharingLocalState.reset() },
         makeListener: @escaping @Sendable () -> any ChatGPTLoopbackListening = { ChatGPTLoopbackListener() },
         openBrowser: @escaping @Sendable (URL) async -> Bool = { url in await MainActor.run { SystemBrowserOpener().open(url) } }) {
        self.storage = storage
        self.transport = transport
        self.configuration = configuration
        self.checkPrivacy = checkPrivacy
        self.resetLocalState = resetLocalState
        self.makeListener = makeListener
        self.openBrowser = openBrowser
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

    /// - Parameter access: what the caller will do with the folder (see `DriveFolderAccess`).
    func chooseFolder(access: DriveFolderAccess = .publish) async throws -> DriveProjectFolder {
        guard let folder = try await authorize(pickFolder: true, folderAccess: access) else {
            throw GoogleDriveSharingError.consent
        }
        return folder
    }

    private func authorize(pickFolder: Bool, folderAccess: DriveFolderAccess = .publish) async throws -> DriveProjectFolder? {
        try checkPrivacy()
        guard !isAuthorizing, !isDisconnecting else { throw GoogleDriveSharingError.busy }
        isAuthorizing = true
        defer { isAuthorizing = false }
        let client = try configuration()
        let state = try PKCEHelper.generateRandomToken()
        let verifier = try PKCEHelper.generateCodeVerifier()
#if os(iOS)
        guard let scheme = client.redirectScheme else { throw GoogleDriveSharingError.configuration }
        let redirect = scheme + ":/oauth2redirect"
#else
        let listener = makeListener()
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
        guard await openBrowser(authURL) else { throw GoogleDriveSharingError.consent }
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
            folder = try await remote.validateFolder(id: pickedID, access: folderAccess)
        }
        try checkPrivacy()
        try await storage.save(credential(tokens, refresh: refresh))
        // Same grant family, so running uploads keep their `connectionID`; only refreshes that began
        // against the previous credential must not overwrite this one.
        credentialGeneration += 1
        return folder
    }

    func sharingParent(of folder: DriveProjectFolder) async throws -> DriveProjectFolder? {
        let token = try await uploadToken()
        return try await DriveProjectRemote(transport: transport, checkPrivacy: checkPrivacy, token: token)
            .sharingParent(of: folder)
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
        if let refresh { return try await awaitRefresh(refresh, connection: connection) }
        let client = try configuration()
        let generation = credentialGeneration
        guard let previous = try await storage.load() else { throw GoogleDriveSharingError.signInRequired }
        guard connection == connectionID else { throw GoogleDriveSharingError.signInRequired }
        if previous.accessToken != rejected, previous.expiresAt.timeIntervalSinceNow > 60 {
            return previous.accessToken
        }
        // Another caller may have started a refresh while the credential was loading.
        if let refresh { return try await awaitRefresh(refresh, connection: connection) }
        let id = UUID()
        let task = Task { try await self.refreshCredential(previous, client: client, generation: generation) }
        refresh = (id, task)
        return try await awaitRefresh((id, task), connection: connection)
    }

    private func awaitRefresh(_ current: (id: UUID, task: Task<String, Error>), connection: UUID) async throws -> String {
        let result = await current.task.result
        if refresh?.id == current.id { refresh = nil }
        let token = try result.get()
        guard connection == connectionID else { throw GoogleDriveSharingError.signInRequired }
        try checkPrivacy()
        return token
    }

    private func refreshCredential(_ previous: GoogleOAuthCredential, client: GoogleOAuthConfiguration,
                                   generation: Int) async throws -> String {
        let updated = try await token(["grant_type": "refresh_token", "refresh_token": previous.refreshToken],
                                      client: client, requireScope: false, generation: generation)
        if generation == credentialGeneration {
            try await storage.save(credential(updated, refresh: updated.refresh_token ?? previous.refreshToken))
            credentialGeneration += 1
        }
        return updated.access_token
    }

    /// Always offers local disconnect, including while Local Only is enabled.
    func disconnect() async throws {
        guard !isAuthorizing, !isDisconnecting else { throw GoogleDriveSharingError.busy }
        isDisconnecting = true
        defer { isDisconnecting = false }
        let stored = try await storage.load()
        try await storage.delete()
        connectionID = UUID()
        credentialGeneration += 1
        refresh = nil
        await resetLocalState()
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
                       requireScope: Bool, generation: Int? = nil) async throws -> Tokens {
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
            // Only discard the credential this refresh was based on, never a newer authorization.
            if generation == nil || generation == credentialGeneration {
                try await storage.delete()
                connectionID = UUID()
                credentialGeneration += 1
            }
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
