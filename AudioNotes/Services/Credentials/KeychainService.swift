import Foundation
import Security

enum CredentialAccount: String, Sendable { case openAI = "openai-api-key", anthropic = "anthropic-api-key", gemini = "gemini-api-key" }

protocol CredentialStoring: Sendable {
    func containsKey(for account: CredentialAccount) async throws -> Bool
    func apiKey(for account: CredentialAccount) async throws -> String?
    func saveAPIKey(_ key: String, for account: CredentialAccount) async throws
    func deleteAPIKey(for account: CredentialAccount) async throws
}

enum KeychainError: Error, LocalizedError, Equatable {
    case accessDenied, locked, unavailable, invalidKey, invalidData
    case unexpectedStatus(OSStatus)

    init(status: OSStatus) {
        switch status {
        case errSecAuthFailed, errSecUserCanceled: self = .accessDenied
        case errSecInteractionNotAllowed: self = .locked
        case errSecNotAvailable: self = .unavailable
        default: self = .unexpectedStatus(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Keychain access was denied. Allow AudioNotes to access its saved credential."
        case .locked: "Keychain is locked or cannot prompt for access. Unlock it and try again."
        case .unavailable: "macOS Keychain is currently unavailable. Please try again."
        case .invalidKey: "Enter a nonempty API key without spaces or line breaks."
        case .invalidData: "The saved credential could not be read. Remove it and save a new key."
        case .unexpectedStatus(let status): "Keychain could not complete the operation (\(status))."
        }
    }
}

enum APIKeyInput {
    static func normalized(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw KeychainError.invalidKey
        }
        return key
    }
}

/// Uses a device-local generic-password item. No credentials are stored in preferences.
actor KeychainService: CredentialStoring {
    private let service: String

    init(service: String = "cz.kudladev.AudioNotes.provider-credentials") {
        self.service = service
    }

    private func query(_ account: CredentialAccount) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    func containsKey(for account: CredentialAccount) throws -> Bool {
        var request = query(account)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // Checking presence does not load the saved secret into Settings.
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return true
    }

    func apiKey(for account: CredentialAccount) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return key
    }

    func saveAPIKey(_ value: String, for account: CredentialAccount) throws {
        let key = try APIKeyInput.normalized(value)
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func deleteAPIKey(for account: CredentialAccount) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
