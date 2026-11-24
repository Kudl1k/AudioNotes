import Foundation
import OSLog

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
    private let onSessionExpired: @MainActor @Sendable () -> Void
    private var refreshTask: Task<String, Error>?
    private var isDisconnecting = false
    private var pendingRefresh: PendingRefresh?

    private struct PendingRefresh {
        let account: ChatGPTAccount
        let accessToken: String
        let refreshToken: String
        let idToken: String?
    }

    private static let logger = Logger(subsystem: "cz.kudladev.soniquill", category: "ChatGPTOAuth")
    private static let tokenURL = "https://auth.openai.com/api/accounts/oauth/token"
    private static let resource = "https://api.openai.com/v1"

    init(
        credentialStore: any ChatGPTCredentialStoring = ChatGPTCredentialStore(),
        urlSession: URLSession = .shared,
        sessionStore: any ChatGPTSessionStoring = ChatGPTUserDefaultsSessionStore(),
        onSessionExpired: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.credentialStore = credentialStore
        self.urlSession = urlSession
        self.sessionStore = sessionStore
        self.onSessionExpired = onSessionExpired
    }

    /// Returns a valid bearer access token, refreshing it automatically if expired or nearing expiry.
    func validAccessToken(clockTolerance: TimeInterval = 60) async throws -> String {
        guard !isDisconnecting else { throw ChatGPTAuthError.sessionExpired }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.loadOrRefreshToken(clockTolerance: clockTolerance) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func beginDisconnect() async -> String? {
        isDisconnecting = true
        if let refreshTask {
            _ = await refreshTask.result
        }
        return pendingRefresh?.refreshToken
    }

    func endDisconnect(didClearCredentials: Bool) {
        if didClearCredentials { pendingRefresh = nil }
        isDisconnecting = false
    }

    private func loadOrRefreshToken(clockTolerance: TimeInterval) async throws -> String {
        if pendingRefresh != nil { try await persistPendingRefresh() }
        guard let account = sessionStore.loadAccount() else {
            throw ChatGPTAuthError.sessionExpired
        }

        let now = Date()
        // OpenAI's SIWC token response can carry earliest_refresh_at. Honor it
        // so concurrently initiated work doesn't rotate before the token is renewable.
        if let earliestRefreshAt = account.earliestRefreshAt, now < earliestRefreshAt,
           account.expiresAt > now {
            if let existingToken = try await credentialStore.accessToken(), !existingToken.isEmpty { return existingToken }
        }

        // Check if access token is still fresh.
        if account.expiresAt.timeIntervalSince(now) > clockTolerance {
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

        Self.logger.notice("ChatGPT OAuth refresh: starting")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            Self.logger.notice("ChatGPT OAuth refresh: network_failure")
            throw ChatGPTAuthError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTAuthError.network("Invalid server response")
        }

        // Specific handling for HTTP 400 invalid_grant/token expired
        if http.statusCode == 400 || http.statusCode == 401 {
            let code = try? JSONDecoder().decode(RefreshErrorResponse.self, from: data).error
            if let code, isTerminalRefreshError(code) {
                // Keep the issued client mapping for reauthorization.
                try await credentialStore.clearTokens()
                await onSessionExpired()
                Self.logger.notice("ChatGPT OAuth refresh: reauthentication_required")
                throw ChatGPTAuthError.sessionExpired
            }
            throw ChatGPTAuthError.tokenExchangeFailed(status: http.statusCode, message: ChatGTPOAuthDiagnostics.safeCode(from: data))
        }

        guard (200...299).contains(http.statusCode) else {
            throw ChatGPTAuthError.tokenExchangeFailed(status: http.statusCode, message: ChatGTPOAuthDiagnostics.safeCode(from: data))
        }

        let tokenResponse: ChatGPTTokenResponse
        do {
            tokenResponse = try JSONDecoder().decode(ChatGPTTokenResponse.self, from: data)
        } catch {
            throw ChatGPTAuthError.invalidTokenResponse
        }

        guard !tokenResponse.accessToken.isEmpty, tokenResponse.expiresIn > 0,
              tokenResponse.refreshToken?.isEmpty != true else {
            throw ChatGPTAuthError.invalidTokenResponse
        }

        // Retain original refresh token if server did not rotate it
        let newRefreshToken = tokenResponse.refreshToken ?? refreshToken
        let newExpiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))

        // Update account session metadata
        let updatedAccount = ChatGPTAccount(
            id: account.id,
            email: account.email,
            displayName: account.displayName,
            issuedClientID: account.issuedClientID,
            grantedScopes: tokenResponse.grantedScopes.isEmpty ? account.grantedScopes : tokenResponse.grantedScopes,
            planUsageEnabled: tokenResponse.hasPlanUsageScope || account.planUsageEnabled,
            expiresAt: newExpiresAt,
            earliestRefreshAt: tokenResponse.earliestRefreshAt
        )

        // If the device locks before the Keychain write, retry this write on the next
        // request instead of presenting the already-rotated token to the server again.
        pendingRefresh = PendingRefresh(account: updatedAccount, accessToken: tokenResponse.accessToken,
                                        refreshToken: newRefreshToken, idToken: tokenResponse.idToken)
        try await persistPendingRefresh()
        return tokenResponse.accessToken
    }

    private func persistPendingRefresh() async throws {
        guard let pendingRefresh else { return }
        try await credentialStore.saveTokens(accessToken: pendingRefresh.accessToken,
                                             refreshToken: pendingRefresh.refreshToken, idToken: pendingRefresh.idToken)
        sessionStore.saveAccount(pendingRefresh.account)
        self.pendingRefresh = nil
        Self.logger.notice("ChatGPT OAuth refresh: saved")
    }

    private struct RefreshErrorResponse: Decodable { let error: String }

    private func isTerminalRefreshError(_ code: String) -> Bool {
        let codes = [
            "invalid_grant",
            "invalid_refresh_token",
            "token_expired",
            "refresh_token_expired",
            "refresh_token_invalidated",
            "refresh_token_reused"
        ]
        return codes.contains(code)
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
