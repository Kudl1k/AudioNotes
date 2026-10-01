import Foundation
@testable import AudioNotes

actor MockCredentialStore: CredentialStoring {
    private var keys: [CredentialAccount: String] = [:]
    var failure: KeychainError?
    private(set) var secretReads = 0

    init(key: String? = nil, failure: KeychainError? = nil) {
        keys[.openAI] = key
        self.failure = failure
    }
    func containsKey(for account: CredentialAccount) throws -> Bool {
        if let failure { throw failure }
        return keys[account] != nil
    }
    func apiKey(for account: CredentialAccount) throws -> String? {
        if let failure { throw failure }
        secretReads += 1
        return keys[account]
    }
    func saveAPIKey(_ key: String, for account: CredentialAccount) throws {
        if let failure { throw failure }
        keys[account] = try APIKeyInput.normalized(key)
    }
    func deleteAPIKey(for account: CredentialAccount) throws {
        if let failure { throw failure }
        keys[account] = nil
    }
}
