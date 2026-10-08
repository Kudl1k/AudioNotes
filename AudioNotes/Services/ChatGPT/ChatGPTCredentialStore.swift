import Foundation
import Security

protocol ChatGPTCredentialStoring: Sendable {
    func saveTokens(accessToken: String, refreshToken: String?, idToken: String?) async throws
    func accessToken() async throws -> String?
    func refreshToken() async throws -> String?
    func idToken() async throws -> String?
    func clearTokens() async throws
}

actor ChatGPTCredentialStore: ChatGPTCredentialStoring {
    // Stable lookup identity across the Soniquill product rename.
    static let defaultService = "cz.kudladev.AudioNotes.chatgpt-credentials"

    private let service: String

    private enum TokenKey: String {
        case accessToken = "chatgpt.oauth.access_token"
        case refreshToken = "chatgpt.oauth.refresh_token"
        case idToken = "chatgpt.oauth.id_token"
    }

    init(service: String = ChatGPTCredentialStore.defaultService) {
        self.service = service
    }

    private func query(for key: TokenKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func saveToken(_ token: String?, for key: TokenKey) throws {
        guard let token, !token.isEmpty else {
            try deleteToken(for: key)
            return
        }
        let attributes = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query(for: key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(for: key)
            item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private func readToken(for key: TokenKey) throws -> String? {
        var request = query(for: key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return token
    }

    private func deleteToken(for key: TokenKey) throws {
        let status = SecItemDelete(query(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    func saveTokens(accessToken: String, refreshToken: String?, idToken: String?) throws {
        try saveToken(accessToken, for: .accessToken)
        try saveToken(refreshToken, for: .refreshToken)
        try saveToken(idToken, for: .idToken)
    }

    func accessToken() throws -> String? {
        try readToken(for: .accessToken)
    }

    func refreshToken() throws -> String? {
        try readToken(for: .refreshToken)
    }

    func idToken() throws -> String? {
        try readToken(for: .idToken)
    }

    func clearTokens() throws {
        try deleteToken(for: .accessToken)
        try deleteToken(for: .refreshToken)
        try deleteToken(for: .idToken)
    }
}
