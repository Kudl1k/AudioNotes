import AppKit
import Foundation
import Security

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
    private let service: String
    private let account = "google-gemini-oauth"
    private let clientSecretAccount = "google-gemini-oauth-client-secret"

    init(service: String = "cz.kudladev.AudioNotes.provider-credentials") { self.service = service }

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
    case missingClientID
    case invalidState
    case authorization(String)
    case tokenExchange(String)
    case missingRefreshToken
    case reauthenticationRequired

    var errorDescription: String? {
        switch self {
        case .missingClientID: "The app’s Google OAuth configuration is missing its Desktop client ID."
        case .invalidState: "Google sign-in could not be verified. Please try again."
        case .authorization(let message): "Google authorization failed: \(message)"
        case .tokenExchange(let reason): "Google OAuth token exchange failed (\(reason)). Check that the OAuth client is a Desktop app and that the sign-in flow uses its matching redirect and PKCE verifier."
        case .missingRefreshToken: "Google did not issue a refresh token. Disconnect and reconnect with consent."
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
    private let scopes = ["openid", "email", "https://www.googleapis.com/auth/generative-language.retriever"]

    init(configuration: @escaping @Sendable () throws -> GoogleOAuthConfiguration = { try GoogleOAuthConfiguration.load() }, store: any GoogleOAuthCredentialStoring = GoogleOAuthKeychainStore(), clientSecretStore: (any GoogleOAuthClientSecretStoring)? = nil, listener: any ChatGPTLoopbackListening = ChatGPTLoopbackListener(), session: URLSession = .shared, openURL: @escaping @Sendable (URL) async -> Bool = { url in NSWorkspace.shared.open(url) }, now: @escaping @Sendable () -> Date = Date.init) {
        self.configuration = configuration
        self.store = store
        self.clientSecretStore = clientSecretStore ?? (store as? any GoogleOAuthClientSecretStoring) ?? GoogleOAuthKeychainStore()
        self.listener = listener
        self.session = session
        self.openURL = openURL
        self.now = now
    }

    func account() async -> ProviderAccount? {
        guard let credential = try? await store.load() else { return nil }
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
        let client = try await configuredClient()
        let clientID = client.clientID
        let (listenerRedirectURI, _) = try await listener.start()
        defer { listener.cancel() }
        // Google desktop clients use the loopback IP and dynamic port with no callback path.
        let redirectURI = listenerRedirectURI.replacingOccurrences(of: "/auth/callback", with: "")
        let state = try PKCEHelper.generateRandomToken()
        let verifier = try PKCEHelper.generateCodeVerifier()
        let challenge = PKCEHelper.generateCodeChallenge(from: verifier)
        let authURL = try Self.authorizationURL(clientID: clientID, redirectURI: redirectURI, state: state, challenge: challenge, scopes: scopes)
        guard await openURL(authURL) else { throw GoogleGeminiOAuthError.authorization("Could not open the system browser.") }
        let callback = try await listener.waitForCallback(timeout: 300)
        guard Self.callbackMatchesState(callback.state, expected: state) else { throw GoogleGeminiOAuthError.invalidState }
        if let error = callback.error { throw GoogleGeminiOAuthError.authorization(callback.errorDescription ?? error) }
        guard let code = callback.code else { throw GoogleGeminiOAuthError.authorization("Google returned no authorization code.") }
        let clientSecret = try await clientSecretStore.loadClientSecret()
        let tokens = try await exchange(code: code, verifier: verifier, clientID: clientID, clientSecret: clientSecret, redirectURI: redirectURI)
        guard let refresh = tokens.refreshToken else { throw GoogleGeminiOAuthError.missingRefreshToken }
        let email = try await fetchEmail(accessToken: tokens.accessToken)
        let credential = GoogleOAuthCredential(accessToken: tokens.accessToken, refreshToken: refresh, expiresAt: now().addingTimeInterval(TimeInterval(tokens.expiresIn)), email: email)
        try await store.save(credential)
        return ProviderAccount(provider: .gemini, accountIdentifier: email, displayName: nil, email: email, authenticationMethod: .oauth, state: .connected, capabilities: [.textGeneration, .tokenRefresh])
    }

    func validAccessToken() async throws -> String {
        let client = try await configuredClient()
        guard let credential = try await store.load() else { throw GoogleGeminiOAuthError.missingRefreshToken }
        if credential.expiresAt.timeIntervalSince(now()) > 60 { return credential.accessToken }
        let refreshed = try await refresh(refreshToken: credential.refreshToken, clientID: client.clientID, clientSecret: try await clientSecretStore.loadClientSecret())
        let newCredential = GoogleOAuthCredential(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken ?? credential.refreshToken, expiresAt: now().addingTimeInterval(TimeInterval(refreshed.expiresIn)), email: credential.email)
        try await store.save(newCredential)
        return newCredential.accessToken
    }

    func requestHeaders() async throws -> [String: String] {
        let client = try configuration()
        return ["Authorization": "Bearer \(try await validAccessToken())", "x-goog-user-project": client.projectID]
    }

    func disconnect() async throws { try await store.delete() }

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

    private struct TokenResponse: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int }
    private struct TokenErrorResponse: Decodable { let error: String?; let error_description: String? }
    private func exchange(code: String, verifier: String, clientID: String, clientSecret: String?, redirectURI: String) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let parameters = Self.tokenParameters(["code": code, "client_id": clientID, "redirect_uri": redirectURI, "grant_type": "authorization_code", "code_verifier": verifier], clientSecret: clientSecret)
        request.httpBody = Self.form(parameters)
        let (data, response) = try await session.data(for: request)
        guard let response = try tokenResponse(data: data, response: response) else { throw GoogleGeminiOAuthError.tokenExchange("invalid response") }
        return (response.access_token, response.refresh_token, response.expires_in)
    }

    private func refresh(refreshToken: String, clientID: String, clientSecret: String?) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let parameters = Self.tokenParameters(["refresh_token": refreshToken, "client_id": clientID, "grant_type": "refresh_token"], clientSecret: clientSecret)
        request.httpBody = Self.form(parameters)
        let (data, response) = try await session.data(for: request)
        guard let response = try tokenResponse(data: data, response: response, isRefresh: true) else {
            if safeOAuthError(data: data, status: (response as? HTTPURLResponse)?.statusCode).hasSuffix("invalid_grant") {
                try? await store.delete()
                throw GoogleGeminiOAuthError.reauthenticationRequired
            }
            throw GoogleGeminiOAuthError.tokenExchange(safeOAuthError(data: data, status: (response as? HTTPURLResponse)?.statusCode))
        }
        return (response.access_token, response.refresh_token, response.expires_in)
    }

    private func tokenResponse(data: Data, response: URLResponse, isRefresh: Bool = false) throws -> TokenResponse? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if isRefresh, safeOAuthError(data: data, status: (response as? HTTPURLResponse)?.statusCode).hasSuffix("invalid_grant") { return nil }
            throw GoogleGeminiOAuthError.tokenExchange(safeOAuthError(data: data, status: (response as? HTTPURLResponse)?.statusCode))
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data), !token.access_token.isEmpty else {
            throw GoogleGeminiOAuthError.tokenExchange("malformed success response")
        }
        return token
    }

    /// Exposes only Google's stable error code and HTTP status; response bodies and credentials are never logged or shown.
    private func safeOAuthError(data: Data, status: Int?) -> String {
        let serverError = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
        let code = serverError?.error
            .flatMap { value -> String? in
                let safe = value.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
                return safe.isEmpty ? nil : safe
            }
        let description: String? = serverError?.error_description.flatMap { value in
            let printableASCII = value.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }
            let sanitized = String(String.UnicodeScalarView(printableASCII).prefix(140))
            return sanitized.isEmpty ? nil : sanitized
        }
        let details = [code, description].compactMap { $0 }.joined(separator: ": ")
        if let status { return details.isEmpty ? "HTTP \(status)" : "HTTP \(status), \(details)" }
        return details.isEmpty ? "unrecognized response" : details
    }

    private func fetchEmail(accessToken: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
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
