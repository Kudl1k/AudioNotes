import Foundation
import Security
import OSLog

struct GoogleOAuthCredential: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String?
}

protocol GoogleOAuthCredentialStoring: Sendable {
    func load() async throws -> GoogleOAuthCredential?
    func save(_ credential: GoogleOAuthCredential) async throws
    func delete() async throws
}

protocol GoogleOAuthClientSecretStoring: Sendable {
    func loadClientSecret() async throws -> String?
    func saveClientSecret(_ secret: String) async throws
    func deleteClientSecret() async throws
}

actor GoogleOAuthKeychainStore: GoogleOAuthCredentialStoring, GoogleOAuthClientSecretStoring {
    // Stable lookup identity across the Soniquill product rename.
    static let defaultService = "cz.kudladev.AudioNotes.provider-credentials"

    private let service: String
    private let account = "google-gemini-oauth"
    private let clientSecretAccount: String

    init(service: String = GoogleOAuthKeychainStore.defaultService,
         clientSecretAccount: String = "google-gemini-oauth-client-secret") {
        self.service = service
        self.clientSecretAccount = clientSecretAccount
    }

    func load() throws -> GoogleOAuthCredential? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecAttrSynchronizable as String: false,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(GoogleOAuthCredential.self, from: data)
    }

    func save(_ credential: GoogleOAuthCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecAttrSynchronizable as String: false]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        } else if update != errSecSuccess { throw KeychainError(status: update) }
    }

    func delete() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecAttrSynchronizable as String: false]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    func loadClientSecret() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: clientSecretAccount,
                                    kSecAttrSynchronizable as String: false,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        return value
    }

    func saveClientSecret(_ secret: String) throws {
        let normalized = try APIKeyInput.normalized(secret)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: clientSecretAccount,
                                    kSecAttrSynchronizable as String: false]
        let attrs = [kSecValueData as String: Data(normalized.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(normalized.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    func deleteClientSecret() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: clientSecretAccount,
                                    kSecAttrSynchronizable as String: false]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

enum GoogleGeminiOAuthError: LocalizedError, Equatable {
    case cancelled
    case missingClientID
    case invalidState
    case authorization(String)
    case tokenExchange(String)
    case missingRefreshToken
    case reauthenticationRequired

    var errorDescription: String? {
        switch self {
        case .cancelled: "Google sign-in was canceled."
        case .missingClientID: "The app’s Google OAuth configuration is missing its client ID."
        case .invalidState: "Google sign-in could not be verified. Please try again."
        case .authorization(let message): "Google authorization failed: \(message)"
        case .tokenExchange(let reason): "Google OAuth token exchange failed (\(reason)). Check the configured OAuth client and its redirect."
        case .missingRefreshToken: "Connect a Google account in Settings → AI Accounts before using Gemini."
        case .reauthenticationRequired: "Google authorization expired or was revoked. Sign in with Google again."
        }
    }
}

/// Installed-app OAuth with the system browser, a loopback redirect, state, and PKCE.
actor GoogleGeminiOAuthService {
    private let configuration: @Sendable () throws -> GoogleOAuthConfiguration
    private let store: any GoogleOAuthCredentialStoring
    private let clientSecretStore: any GoogleOAuthClientSecretStoring
    private let listener: any ChatGPTLoopbackListening
    private let session: URLSession
    private let openURL: @Sendable (URL) async -> Bool
    private let now: @Sendable () -> Date
    private let nativeAuthenticate: @Sendable (URL, String) async throws -> URL
    // Google's Gemini OAuth quickstart uses cloud-platform plus the Gemini
    // API scope. Google account identity alone does not grant Gemini API use.
    private let scopes = ["openid", "email", "https://www.googleapis.com/auth/cloud-platform", "https://www.googleapis.com/auth/generative-language.retriever"]
    private var refreshTask: Task<String, Error>?
    private var isDisconnecting = false
    private static let logger = Logger(subsystem: "cz.kudladev.soniquill", category: "GoogleOAuth")

    private enum ConnectPhase: String {
        case configuration, browser, callback, tokenExchange, userInfo, keychainSave
    }

    private static func diagnosticCategory(for error: Error) -> String {
        switch error {
        case is GoogleOAuthConfigurationError: "configuration"
        case is URLError: "network"
        case is KeychainError: "keychain"
        case GoogleGeminiOAuthError.cancelled, is CancellationError: "cancelled"
        case GoogleGeminiOAuthError.invalidState: "invalid_state"
        case GoogleGeminiOAuthError.missingRefreshToken: "missing_refresh_token"
        case GoogleGeminiOAuthError.authorization: "authorization"
        case GoogleGeminiOAuthError.tokenExchange: "token_response"
        default: "unexpected"
        }
    }

    init(configuration: @escaping @Sendable () throws -> GoogleOAuthConfiguration = { try GoogleOAuthConfiguration.load() }, store: any GoogleOAuthCredentialStoring = GoogleOAuthKeychainStore(), clientSecretStore: (any GoogleOAuthClientSecretStoring)? = nil, listener: any ChatGPTLoopbackListening = ChatGPTLoopbackListener(), session: URLSession = .shared, openURL: @escaping @Sendable (URL) async -> Bool = { url in SystemBrowserOpener().open(url) }, now: @escaping @Sendable () -> Date = Date.init, nativeAuthenticate: @escaping @Sendable (URL, String) async throws -> URL = GoogleGeminiOAuthService.defaultNativeAuthenticate) {
        self.configuration = configuration
        self.store = store
        self.clientSecretStore = clientSecretStore ?? (store as? any GoogleOAuthClientSecretStoring) ?? GoogleOAuthKeychainStore()
        self.listener = listener
        self.session = session
        self.openURL = openURL
        self.now = now
        self.nativeAuthenticate = nativeAuthenticate
    }

    private static func defaultNativeAuthenticate(url: URL, scheme: String) async throws -> URL {
#if os(iOS)
        try await GoogleOAuthAuthenticationSession.authenticate(url: url, callbackScheme: scheme)
#else
        throw GoogleGeminiOAuthError.authorization("Native Google authentication sessions are only available on iOS.")
#endif
    }

    func account() async -> ProviderAccount? {
        let credential: GoogleOAuthCredential
        do {
            guard let stored = try await store.load() else { return nil }
            credential = stored
        } catch {
            Self.logger.error("Google OAuth account_load: keychain_read_failed")
            return nil
        }
        return ProviderAccount(provider: .gemini, accountIdentifier: credential.email, displayName: nil, email: credential.email, authenticationMethod: .oauth, state: .connected, capabilities: [.textGeneration, .tokenRefresh])
    }

    func configurationStatus() -> String? {
        do { _ = try configuration(); return nil }
        catch { return error.localizedDescription }
    }

    /// Synchronize the developer file into Keychain; never use a legacy user-entered secret.
    private func configuredClient() async throws -> GoogleOAuthConfiguration {
        let client = try configuration()
        if let secret = client.clientSecret {
            try await clientSecretStore.saveClientSecret(secret)
        } else {
            try await clientSecretStore.deleteClientSecret()
        }
        return client
    }

    func connect() async throws -> ProviderAccount {
        var phase = ConnectPhase.configuration
        do {
            let client = try await configuredClient()
            let clientID = client.clientID
#if os(iOS)
            guard let callbackScheme = client.redirectScheme else { throw GoogleOAuthConfigurationError.missingIOSClient }
            let redirectURI = callbackScheme + ":/oauth2redirect"
#else
            let (listenerRedirectURI, _) = try await listener.start()
            defer { listener.cancel() }
            // Google desktop clients use the loopback IP and dynamic port with no callback path.
            let redirectURI = listenerRedirectURI.replacingOccurrences(of: "/auth/callback", with: "")
#endif
            let state = try PKCEHelper.generateRandomToken()
            let verifier = try PKCEHelper.generateCodeVerifier()
            let challenge = PKCEHelper.generateCodeChallenge(from: verifier)
            let authURL = try Self.authorizationURL(clientID: clientID, redirectURI: redirectURI, state: state, challenge: challenge, scopes: scopes)
            phase = .browser
            Self.logger.notice("Google OAuth browser: starting")
            let callback: ChatGPTCallbackResult
#if os(iOS)
            let callbackURL = try await nativeAuthenticate(authURL, callbackScheme)
            phase = .callback
            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  components.scheme == callbackScheme, components.host == nil,
                  components.path == "/oauth2redirect" else {
                throw GoogleGeminiOAuthError.authorization("Unexpected Google callback address.")
            }
            callback = Self.callbackResult(from: callbackURL)
#else
            guard await openURL(authURL) else { throw GoogleGeminiOAuthError.authorization("Could not open the system browser.") }
            callback = try await listener.waitForCallback(timeout: 300)
#endif
            phase = .callback
            guard Self.callbackMatchesState(callback.state, expected: state) else { throw GoogleGeminiOAuthError.invalidState }
            if let error = callback.error { throw GoogleGeminiOAuthError.authorization(Self.knownOAuthCode(error)) }
            guard let code = callback.code else { throw GoogleGeminiOAuthError.authorization("Google returned no authorization code.") }
            phase = .tokenExchange
            Self.logger.notice("Google OAuth callback: verified")
            let clientSecret = client.clientSecret
            let tokens = try await exchange(code: code, verifier: verifier, clientID: clientID, clientSecret: clientSecret, redirectURI: redirectURI)
            guard let refresh = tokens.refreshToken, !refresh.isEmpty else { throw GoogleGeminiOAuthError.missingRefreshToken }
            phase = .userInfo
            let email: String?
            do {
                email = try await fetchEmail(accessToken: tokens.accessToken)
            } catch {
                try Task.checkCancellation()
                Self.logger.notice("Google OAuth userInfo: unavailable")
                email = nil
            }
            try Task.checkCancellation()
            phase = .keychainSave
            let credential = GoogleOAuthCredential(accessToken: tokens.accessToken, refreshToken: refresh, expiresAt: now().addingTimeInterval(TimeInterval(tokens.expiresIn)), email: email)
            try await store.save(credential)
            Self.logger.notice("Google OAuth keychainSave: connected")
            return ProviderAccount(provider: .gemini, accountIdentifier: email, displayName: nil, email: email, authenticationMethod: .oauth, state: .connected, capabilities: [.textGeneration, .tokenRefresh])
        } catch {
            Self.logger.error("Google OAuth \(phase.rawValue, privacy: .public): \(Self.diagnosticCategory(for: error), privacy: .public)")
            if error is URLError {
                throw GoogleGeminiOAuthError.authorization("Network request failed during \(phase.rawValue).")
            }
            throw error
        }
    }

    func validAccessToken() async throws -> String {
        guard !isDisconnecting else { throw GoogleGeminiOAuthError.reauthenticationRequired }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.loadOrRefreshToken() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func loadOrRefreshToken() async throws -> String {
        let client = try await configuredClient()
        guard let credential = try await store.load() else { throw GoogleGeminiOAuthError.missingRefreshToken }
        if credential.expiresAt.timeIntervalSince(now()) > 60 { return credential.accessToken }
        return try await performRefresh(credential: credential, clientID: client.clientID, clientSecret: client.clientSecret)
    }

    func requestHeaders() async throws -> [String: String] {
        let client = try configuration()
        return ["Authorization": "Bearer \(try await validAccessToken())", "x-goog-user-project": client.projectID]
    }

    func disconnect() async throws {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        defer { isDisconnecting = false }
        if let refreshTask { _ = await refreshTask.result }
        if let credential = try? await store.load() {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": credential.refreshToken])
            // Revoke remotely when reachable, then always remove local secrets.
            _ = try? await session.data(for: request)
        }
        try await store.delete()
    }

    private func performRefresh(credential: GoogleOAuthCredential, clientID: String, clientSecret: String?) async throws -> String {
        Self.logger.notice("Google OAuth refresh: starting")
        let refreshed = try await refresh(refreshToken: credential.refreshToken, clientID: clientID, clientSecret: clientSecret)
        try Task.checkCancellation()
        let updated = GoogleOAuthCredential(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken ?? credential.refreshToken,
                                            expiresAt: now().addingTimeInterval(TimeInterval(refreshed.expiresIn)), email: credential.email)
        try await store.save(updated)
        Self.logger.notice("Google OAuth refresh: saved")
        return updated.accessToken
    }

    static func authorizationURL(clientID: String, redirectURI: String, state: String, challenge: String, scopes: [String]) throws -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]
        guard let url = components.url else { throw GoogleGeminiOAuthError.authorization("Could not create sign-in URL.") }
        return url
    }

    static func callbackMatchesState(_ actual: String?, expected: String) -> Bool { actual == expected }

    static func callbackResult(from url: URL) -> ChatGPTCallbackResult {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        return ChatGPTCallbackResult(code: value("code"), state: value("state"), clientID: value("client_id"), error: value("error"), errorDescription: value("error_description"), scope: value("scope"), pickedFileIDs: value("picked_file_ids"))
    }

    private struct TokenResponse: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int }
    private struct TokenErrorResponse: Decodable { let error: String?; let error_description: String? }
    private func exchange(code: String, verifier: String, clientID: String, clientSecret: String?, redirectURI: String) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let parameters = Self.tokenParameters(["code": code, "client_id": clientID, "redirect_uri": redirectURI, "grant_type": "authorization_code", "code_verifier": verifier], clientSecret: clientSecret)
        request.httpBody = Self.form(parameters)
        let (data, response) = try await session.data(for: request)
        let token = try tokenResponse(data: data, response: response)
        return (token.access_token, token.refresh_token, token.expires_in)
    }

    private func refresh(refreshToken: String, clientID: String, clientSecret: String?) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let parameters = Self.tokenParameters(["refresh_token": refreshToken, "client_id": clientID, "grant_type": "refresh_token"], clientSecret: clientSecret)
        request.httpBody = Self.form(parameters)
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 400,
           (try? JSONDecoder().decode(TokenErrorResponse.self, from: data))?.error == "invalid_grant" {
            try await store.delete()
            throw GoogleGeminiOAuthError.reauthenticationRequired
        }
        let token = try tokenResponse(data: data, response: response)
        return (token.access_token, token.refresh_token, token.expires_in)
    }

    private func tokenResponse(data: Data, response: URLResponse) throws -> TokenResponse {
        guard let http = response as? HTTPURLResponse else {
            throw GoogleGeminiOAuthError.tokenExchange("invalid response")
        }
        guard http.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(TokenErrorResponse.self, from: data))?.error
            let category = Self.knownOAuthCode(code)
            Self.logger.error("Google OAuth token endpoint: HTTP \(http.statusCode, privacy: .public), \(category, privacy: .public)")
            throw GoogleGeminiOAuthError.tokenExchange("HTTP \(http.statusCode), \(category)")
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !token.access_token.isEmpty, token.expires_in > 0 else {
            throw GoogleGeminiOAuthError.tokenExchange("malformed success response")
        }
        return token
    }

    private static func knownOAuthCode(_ code: String?) -> String {
        switch code {
        case "access_denied", "admin_policy_enforced", "invalid_client", "invalid_grant",
             "invalid_request", "invalid_scope", "org_internal", "redirect_uri_mismatch",
             "server_error", "temporarily_unavailable", "unauthorized_client", "unsupported_response_type":
            code ?? "provider_error"
        default: "provider_error"
        }
    }

    private func fetchEmail(accessToken: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct UserInfo: Decodable { let email: String? }
        return try? JSONDecoder().decode(UserInfo.self, from: data).email
    }

    private static func form(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    static func tokenParameters(_ values: [String: String], clientSecret: String?) -> [String: String] {
        var parameters = values
        if let clientSecret, !clientSecret.isEmpty { parameters["client_secret"] = clientSecret }
        return parameters
    }
}
