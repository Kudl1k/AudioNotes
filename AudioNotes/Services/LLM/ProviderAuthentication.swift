import Foundation

enum ProviderAuthenticationMethod: String, CaseIterable, Codable, Sendable {
    case apiKey
    case oauth
    case claudeCode
    case chatGPTAccount
    case appAttest
    case workloadIdentity
}

enum ProviderConnectionState: String, Codable, Sendable {
    case disconnected, connecting, connected, expired, needsReauthentication, failed
}

enum ProviderAccountCapability: String, Codable, Sendable {
    case textGeneration
    case modelDiscovery
    case tokenRefresh
}

struct ProviderAccount: Codable, Sendable, Equatable {
    var provider: LLMProviderID
    var accountIdentifier: String?
    var displayName: String?
    var email: String?
    var authenticationMethod: ProviderAuthenticationMethod
    var state: ProviderConnectionState
    var capabilities: Set<ProviderAccountCapability> = []
}
