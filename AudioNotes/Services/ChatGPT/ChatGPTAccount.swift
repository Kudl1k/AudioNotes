import Foundation

/// Represents a verified ChatGPT user account connected via OpenID Connect.
struct ChatGPTAccount: Identifiable, Codable, Equatable, Sendable {
    /// The unique, verified user subject ID (`sub` claim in ID token).
    let id: String
    /// The user's primary email, if provided in identity claims.
    let email: String?
    /// The user's display name, if provided.
    let displayName: String?
    /// The OAuth client ID issued to this registration (e.g. `oaiapp_...`).
    let issuedClientID: String
    /// The scopes granted during authorization.
    let grantedScopes: [String]
    /// Whether ChatGPT plan usage (`chatgpt.tokens.use.direct`) is granted and active.
    let planUsageEnabled: Bool
    /// Expiration timestamp of the current access token.
    let expiresAt: Date

    init(
        id: String,
        email: String? = nil,
        displayName: String? = nil,
        issuedClientID: String,
        grantedScopes: [String],
        planUsageEnabled: Bool,
        expiresAt: Date
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.issuedClientID = issuedClientID
        self.grantedScopes = grantedScopes
        self.planUsageEnabled = planUsageEnabled
        self.expiresAt = expiresAt
    }
}

/// Authentication state for ChatGPT Sign-in.
enum ChatGPTAuthState: Equatable, Sendable {
    case signedOut
    case authorizing
    case signedIn(account: ChatGPTAccount)
    case failed(message: String)

    var isAuthorizing: Bool {
        if case .authorizing = self { return true }
        return false
    }

    var account: ChatGPTAccount? {
        if case .signedIn(let account) = self { return account }
        return nil
    }
}

/// Token response DTO from https://auth.openai.com/api/accounts/oauth/token.
struct ChatGPTTokenResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String
    let expiresIn: Int
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }

    init(
        accessToken: String,
        tokenType: String = "Bearer",
        expiresIn: Int = 3600,
        refreshToken: String? = nil,
        idToken: String? = nil,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.scope = scope
    }

    var grantedScopes: [String] {
        guard let scope else { return [] }
        return scope.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    var hasPlanUsageScope: Bool {
        grantedScopes.contains("chatgpt.tokens.use.direct")
    }
}

/// Thread-safe storage abstraction for non-secret ChatGPT account metadata.
protocol ChatGPTSessionStoring: Sendable {
    func loadAccount() -> ChatGPTAccount?
    func saveAccount(_ account: ChatGPTAccount)
    func clearAccount()
}

/// UserDefaults-backed session store.
final class ChatGPTUserDefaultsSessionStore: ChatGPTSessionStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAccount() -> ChatGPTAccount? {
        guard let data = defaults.data(forKey: "chatgpt.account.session") else { return nil }
        return try? JSONDecoder().decode(ChatGPTAccount.self, from: data)
    }

    func saveAccount(_ account: ChatGPTAccount) {
        if let data = try? JSONEncoder().encode(account) {
            defaults.set(data, forKey: "chatgpt.account.session")
        }
    }

    func clearAccount() {
        defaults.removeObject(forKey: "chatgpt.account.session")
    }
}
