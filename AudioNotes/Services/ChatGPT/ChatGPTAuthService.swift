import Combine
import Foundation

protocol BrowserOpening: Sendable {
    @MainActor func open(_ url: URL) -> Bool
}

enum ChatGPTAuthError: LocalizedError, Equatable {
    case userCanceled
    case accessDenied(message: String?)
    case stateMismatch
    case missingIssuedClientID
    case clientIDMismatch(expected: String, got: String)
    case missingCode
    case invalidTokenResponse
    case tokenExchangeFailed(status: Int, message: String)
    case invalidGrant
    case sessionExpired
    case network(String)

    var errorDescription: String? {
        switch self {
        case .userCanceled:
            "ChatGPT sign-in was canceled."
        case .accessDenied(let msg):
            msg ?? "ChatGPT sign-in access was denied or plan permissions were declined."
        case .stateMismatch:
            "Authentication state mismatch. Please try signing in again."
        case .missingIssuedClientID:
            "ChatGPT did not return an issued client identifier."
        case .clientIDMismatch(let expected, let got):
            "Returned client identifier '\(got)' does not match expected '\(expected)'."
        case .missingCode:
            "No authorization code received from ChatGPT."
        case .invalidTokenResponse:
            "ChatGPT returned an unreadable token response."
        case .tokenExchangeFailed(let status, let msg):
            "Token exchange failed (HTTP \(status)): \(msg)"
        case .invalidGrant:
            "The authorization code was invalid or expired. Please sign in again."
        case .sessionExpired:
            "Your ChatGPT session has expired. Please sign in again."
        case .network(let msg):
            "Network error during authentication: \(msg)"
        }
    }
}

@MainActor
protocol ChatGPTAuthenticating: Sendable {
    var authState: ChatGPTAuthState { get }
    var currentAccount: ChatGPTAccount? { get }
    func signIn() async throws
    func disconnect() async throws
    func restoreSession() async
}

@MainActor
final class ChatGPTAuthService: ObservableObject, ChatGPTAuthenticating {
    private let credentialStore: any ChatGPTCredentialStoring
    private let tokenValidator: ChatGPTIDTokenValidator
    private let browserOpener: any BrowserOpening
    private let loopbackFactory: @Sendable () -> any ChatGPTLoopbackListening
    private let urlSession: URLSession
    private let sessionStore: any ChatGPTSessionStoring

    private static let appName = "AudioNotes"
    private static let authorizeBaseURL = "https://auth.openai.com/api/accounts/authorize"
    private static let tokenURL = "https://auth.openai.com/api/accounts/oauth/token"
    private static let revokeURL = "https://auth.openai.com/api/accounts/oauth/revoke"
    private static let resource = "https://api.openai.com/v1"
    private static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    @Published private(set) var authState: ChatGPTAuthState = .signedOut

    var currentAccount: ChatGPTAccount? {
        authState.account
    }

    init(
        credentialStore: any ChatGPTCredentialStoring = ChatGPTCredentialStore(),
        tokenValidator: ChatGPTIDTokenValidator = ChatGPTIDTokenValidator(),
        browserOpener: any BrowserOpening = SystemBrowserOpener(),
        loopbackFactory: @escaping @Sendable () -> any ChatGPTLoopbackListening = { ChatGPTLoopbackListener() },
        urlSession: URLSession = .shared,
        sessionStore: any ChatGPTSessionStoring = ChatGPTUserDefaultsSessionStore()
    ) {
        self.credentialStore = credentialStore
        self.tokenValidator = tokenValidator
        self.browserOpener = browserOpener
        self.loopbackFactory = loopbackFactory
        self.urlSession = urlSession
        self.sessionStore = sessionStore
    }

    func restoreSession() async {
        guard let savedAccount = sessionStore.loadAccount() else {
            authState = .signedOut
            return
        }

        // Verify tokens exist in Keychain
        guard let accessToken = try? await credentialStore.accessToken(), !accessToken.isEmpty else {
            sessionStore.clearAccount()
            authState = .signedOut
            return
        }

        authState = .signedIn(account: savedAccount)
    }

    func signIn() async throws {
        authState = .authorizing

        let listener = loopbackFactory()
        let redirectURIString: String
        do {
            let (uri, _) = try await listener.start()
            redirectURIString = uri
        } catch {
            authState = .failed(message: error.localizedDescription)
            throw error
        }

        guard let redirectURI = URL(string: redirectURIString) else {
            listener.cancel()
            let err = ChatGPTAuthError.network("Malformed redirect URI.")
            authState = .failed(message: err.localizedDescription)
            throw err
        }

        let codeVerifier = try PKCEHelper.generateCodeVerifier()
        let codeChallenge = PKCEHelper.generateCodeChallenge(from: codeVerifier)
        let state = try PKCEHelper.generateRandomToken()
        let nonce = try PKCEHelper.generateRandomToken()
        let hostID = ChatGPTHostManager.hostID()

        let existingAccount = sessionStore.loadAccount()
        let storedIDToken = try? await credentialStore.idToken()

        let clientIDToUse: String
        let isInitialRegistration: Bool

        if let existingAccount, !existingAccount.issuedClientID.isEmpty {
            clientIDToUse = existingAccount.issuedClientID
            isInitialRegistration = false
        } else {
            clientIDToUse = "dynamic_agent_client"
            isInitialRegistration = true
        }

        let authorizeURL = buildAuthorizeURL(
            clientID: clientIDToUse,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            state: state,
            nonce: nonce,
            hostID: hostID,
            isInitialRegistration: isInitialRegistration,
            existingIDToken: storedIDToken,
            existingEmail: existingAccount?.email
        )

        guard browserOpener.open(authorizeURL) else {
            listener.cancel()
            let err = ChatGPTAuthError.network("Could not launch system browser for ChatGPT authorization.")
            authState = .failed(message: err.localizedDescription)
            throw err
        }

        let callbackResult: ChatGPTCallbackResult
        do {
            callbackResult = try await listener.waitForCallback(timeout: 300)
        } catch {
            authState = .failed(message: error.localizedDescription)
            throw error
        }

        if let errorParam = callbackResult.error {
            if errorParam == "access_denied" {
                let err = ChatGPTAuthError.accessDenied(message: callbackResult.errorDescription)
                authState = .failed(message: err.localizedDescription)
                throw err
            }
            let err = ChatGPTAuthError.accessDenied(message: callbackResult.errorDescription ?? errorParam)
            authState = .failed(message: err.localizedDescription)
            throw err
        }

        guard callbackResult.state == state else {
            let err = ChatGPTAuthError.stateMismatch
            authState = .failed(message: err.localizedDescription)
            throw err
        }

        guard let authCode = callbackResult.code, !authCode.isEmpty else {
            let err = ChatGPTAuthError.missingCode
            authState = .failed(message: err.localizedDescription)
            throw err
        }

        let issuedClientID: String
        if isInitialRegistration {
            guard let returnedClientID = callbackResult.clientID, !returnedClientID.isEmpty else {
                let err = ChatGPTAuthError.missingIssuedClientID
                authState = .failed(message: err.localizedDescription)
                throw err
            }
            issuedClientID = returnedClientID
        } else {
            if let returned = callbackResult.clientID, !returned.isEmpty, returned != clientIDToUse {
                let err = ChatGPTAuthError.clientIDMismatch(expected: clientIDToUse, got: returned)
                authState = .failed(message: err.localizedDescription)
                throw err
            }
            issuedClientID = clientIDToUse
        }

        // Exchange authorization code for tokens
        let tokenResponse = try await exchangeCode(
            authCode: authCode,
            codeVerifier: codeVerifier,
            clientID: issuedClientID,
            redirectURI: redirectURI
        )

        // Validate OIDC claims if ID token provided
        var subject = "chatgpt_user"
        var email: String?
        var displayName: String?

        if let idToken = tokenResponse.idToken {
            let claims = try await tokenValidator.validate(
                idToken: idToken,
                expectedNonce: nonce,
                expectedAudience: issuedClientID
            )
            subject = claims.sub
            email = claims.email
            displayName = claims.name
        }

        let planUsage = tokenResponse.hasPlanUsageScope
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))

        let newAccount = ChatGPTAccount(
            id: subject,
            email: email ?? existingAccount?.email,
            displayName: displayName ?? existingAccount?.displayName,
            issuedClientID: issuedClientID,
            grantedScopes: tokenResponse.grantedScopes,
            planUsageEnabled: planUsage,
            expiresAt: expiresAt
        )

        // Save tokens securely to Keychain
        try await credentialStore.saveTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            idToken: tokenResponse.idToken
        )

        // Save non-sensitive account metadata
        sessionStore.saveAccount(newAccount)

        authState = .signedIn(account: newAccount)
    }

    func disconnect() async throws {
        // Attempt remote revocation if refresh token is present
        if let refreshToken = try? await credentialStore.refreshToken(),
           let account = currentAccount {
            _ = try? await revokeToken(refreshToken: refreshToken, clientID: account.issuedClientID)
        }

        // Clear Keychain tokens
        try await credentialStore.clearTokens()

        // Clear local session metadata
        sessionStore.clearAccount()
        authState = .signedOut
    }

    private func buildAuthorizeURL(
        clientID: String,
        redirectURI: URL,
        codeChallenge: String,
        state: String,
        nonce: String,
        hostID: String,
        isInitialRegistration: Bool,
        existingIDToken: String?,
        existingEmail: String?
    ) -> URL {
        var components = URLComponents(string: Self.authorizeBaseURL)!
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "resource", value: Self.resource)
        ]

        if isInitialRegistration {
            queryItems.append(URLQueryItem(name: "agent_name_hint", value: Self.appName))
        } else {
            if let existingIDToken, !existingIDToken.isEmpty {
                queryItems.append(URLQueryItem(name: "id_token_hint", value: existingIDToken))
            }
            if let existingEmail, !existingEmail.isEmpty {
                queryItems.append(URLQueryItem(name: "login_hint", value: existingEmail))
            }
        }

        components.queryItems = queryItems
        return components.url!
    }

    private func exchangeCode(
        authCode: String,
        codeVerifier: String,
        clientID: String,
        redirectURI: URL
    ) async throws -> ChatGPTTokenResponse {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": authCode,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": codeVerifier,
            "resource": Self.resource
        ]

        request.httpBody = formURLEncode(params)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ChatGPTAuthError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTAuthError.invalidTokenResponse
        }

        if http.statusCode == 400 || http.statusCode == 401 {
            let errorText = String(data: data, encoding: .utf8) ?? ""
            if errorText.contains("invalid_grant") {
                throw ChatGPTAuthError.invalidGrant
            }
            throw ChatGPTAuthError.tokenExchangeFailed(status: http.statusCode, message: errorText)
        }

        guard (200...299).contains(http.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? ""
            throw ChatGPTAuthError.tokenExchangeFailed(status: http.statusCode, message: errorText)
        }

        do {
            return try JSONDecoder().decode(ChatGPTTokenResponse.self, from: data)
        } catch {
            throw ChatGPTAuthError.invalidTokenResponse
        }
    }

    private func revokeToken(refreshToken: String, clientID: String) async throws {
        var request = URLRequest(url: URL(string: Self.revokeURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "token": refreshToken,
            "token_type_hint": "refresh_token",
            "client_id": clientID
        ]

        request.httpBody = formURLEncode(params)
        _ = try? await urlSession.data(for: request)
    }

    private func formURLEncode(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let bodyString = parameters.compactMap { key, value -> String? in
            guard let encKey = key.addingPercentEncoding(withAllowedCharacters: allowed),
                  let encVal = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
                return nil
            }
            return "\(encKey)=\(encVal)"
        }.joined(separator: "&")
        return Data(bodyString.utf8)
    }
}
