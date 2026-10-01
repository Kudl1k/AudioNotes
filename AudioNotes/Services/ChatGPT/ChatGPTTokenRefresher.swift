import Foundation

public protocol ChatGPTTokenRefreshing: Sendable {
    func validAccessToken(clockTolerance: TimeInterval) async throws -> String
}

extension ChatGPTTokenRefreshing {
    public func validAccessToken() async throws -> String {
        try await validAccessToken(clockTolerance: 60)
    }
}

actor ChatGPTTokenRefresher: ChatGPTTokenRefreshing {
    private let credentialStore: any ChatGPTCredentialStoring
    private let urlSession: URLSession
    private let sessionStore: any ChatGPTSessionStoring

    private static let tokenURL = "https://auth.openai.com/api/accounts/oauth/token"
    private static let resource = "https://api.openai.com/v1"

    init(
        credentialStore: any ChatGPTCredentialStoring = ChatGPTCredentialStore(),
        urlSession: URLSession = .shared,
        sessionStore: any ChatGPTSessionStoring = ChatGPTUserDefaultsSessionStore()
    ) {
        self.credentialStore = credentialStore
        self.urlSession = urlSession
        self.sessionStore = sessionStore
    }

    /// Returns a valid bearer access token, refreshing it automatically if expired or nearing expiry.
    func validAccessToken(clockTolerance: TimeInterval = 60) async throws -> String {
        guard let account = sessionStore.loadAccount() else {
            throw ChatGPTAuthError.sessionExpired
        }

        // Check if access token is still fresh
        if account.expiresAt.timeIntervalSinceNow > clockTolerance {
            if let existingToken = try await credentialStore.accessToken(), !existingToken.isEmpty {
                return existingToken
            }
        }

        // Token expired or missing, refresh it using refresh token
        guard let refreshToken = try await credentialStore.refreshToken(), !refreshToken.isEmpty else {
            throw ChatGPTAuthError.sessionExpired
        }

        return try await refreshTokens(refreshToken: refreshToken, account: account)
    }

    private func refreshTokens(refreshToken: String, account: ChatGPTAccount) async throws -> String {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": account.issuedClientID,
            "refresh_token": refreshToken,
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
            throw ChatGPTAuthError.network("Invalid server response")
        }

        // Specific handling for HTTP 400 invalid_grant/token expired
        if http.statusCode == 400 || http.statusCode == 401 {
            let errorText = String(data: data, encoding: .utf8) ?? ""
            if isTerminalRefreshError(errorText) {
                sessionStore.clearAccount()
                // Clear invalid/expired credentials
                try? await credentialStore.clearTokens()
                throw ChatGPTAuthError.sessionExpired
            }
            throw ChatGPTAuthError.tokenExchangeFailed(status: http.statusCode, message: errorText)
        }

        guard (200...299).contains(http.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? ""
            throw ChatGPTAuthError.tokenExchangeFailed(status: http.statusCode, message: errorText)
        }

        let tokenResponse: ChatGPTTokenResponse
        do {
            tokenResponse = try JSONDecoder().decode(ChatGPTTokenResponse.self, from: data)
        } catch {
            throw ChatGPTAuthError.invalidTokenResponse
        }

        // Retain original refresh token if server did not rotate it
        let newRefreshToken = tokenResponse.refreshToken ?? refreshToken
        let newExpiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))

        // Save updated tokens to Keychain
        try await credentialStore.saveTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: newRefreshToken,
            idToken: tokenResponse.idToken
        )

        // Update account session metadata
        let updatedAccount = ChatGPTAccount(
            id: account.id,
            email: account.email,
            displayName: account.displayName,
            issuedClientID: account.issuedClientID,
            grantedScopes: tokenResponse.grantedScopes.isEmpty ? account.grantedScopes : tokenResponse.grantedScopes,
            planUsageEnabled: tokenResponse.hasPlanUsageScope || account.planUsageEnabled,
            expiresAt: newExpiresAt
        )

        sessionStore.saveAccount(updatedAccount)

        return tokenResponse.accessToken
    }

    private func isTerminalRefreshError(_ errorText: String) -> Bool {
        let codes = [
            "invalid_grant",
            "invalid_refresh_token",
            "token_expired",
            "refresh_token_expired",
            "refresh_token_invalidated",
            "refresh_token_reused"
        ]
        return codes.contains { errorText.contains($0) }
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
