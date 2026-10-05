import Foundation
import Observation

enum ProviderExecutionLocation: String, Codable, Sendable {
    case local, remote, cloud
    var title: String {
        switch self { case .local: Self.localTitle; case .remote: "Remote server"; case .cloud: "Cloud" }
    }
    private static var localTitle: String {
#if os(iOS)
        "On Device"
#else
        "Runs on this Mac"
#endif
    }

}

enum LocalAIError: LocalizedError, Equatable, Sendable {
    case privacyBlocked, invalidEndpoint, unreachable(local: Bool), invalidResponse
    case missingModel(String), cloudModel, insufficientDiskSpace, modelBusy, unsupportedHardware
    case inference(String)
    case transportSecurityBlocked, networkUnavailable, hostNotFound, connectionTimedOut
    var errorDescription: String? {
        switch self {
        case .privacyBlocked: "Local Only is enabled. Choose a provider running on this device, or disable Local Only in Settings."
        case .invalidEndpoint: "Enter an HTTP or HTTPS server address without credentials, query parameters, or a path."
        case .unreachable(let local): local ? "Ollama is not reachable. Start Ollama on this Mac and try again." : "The Ollama server is unreachable. Check the server address, published port, and network connection. Also check AudioNotes access in System Settings > Privacy & Security > Local Network."
        case .transportSecurityBlocked: "macOS blocked this HTTP connection. Use HTTPS, an IP address, or a .local hostname, or configure an App Transport Security exception for this server."
        case .networkUnavailable: "The network connection is unavailable or was interrupted. Check your network and AudioNotes access in System Settings > Privacy & Security > Local Network, then try again."
        case .hostNotFound: "The Ollama hostname could not be resolved. Check the server address and local DNS, or use the server's IP address."
        case .connectionTimedOut: "The Ollama server did not respond in time. Check the server, published port, and firewall, then try again."
        case .invalidResponse: "The local AI service returned an invalid response. Check the selected model and try again."
        case .missingModel(let model): "Model \"\(model)\" is not installed. Choose or install this model in Settings."
        case .cloudModel: "This Ollama model uses a cloud backend or has unverified execution metadata. Choose a downloaded local model."
        case .insufficientDiskSpace: "There is insufficient disk space for this model. Free space and try again."
        case .modelBusy: "On-device AI is already processing or managing a model. Wait for it to finish."
        case .unsupportedHardware: "Local Whisper requires Apple Silicon."
        case .inference(let message): message
        }
    }
}

struct OllamaEndpoint: Equatable, Sendable {
    let url: URL
    init(_ address: String) throws {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = text.contains("://") ? text : "http://" + text
        guard let components = URLComponents(string: candidate),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", let url = components.url else { throw LocalAIError.invalidEndpoint }
        self.url = url
    }
    var executionLocation: ProviderExecutionLocation {
        // Exact literals only. No DNS lookup, suffix matching, LAN or .local aliases.
        let host = url.host()?.lowercased() ?? ""
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) ? .local : .remote
    }
}

struct LocalAIPrivacyPolicy: Sendable {
    var localOnly: Bool
    func validate(_ location: ProviderExecutionLocation) throws {
        if localOnly && location != .local { throw LocalAIError.privacyBlocked }
    }
}

@MainActor @Observable
final class LocalAIConfiguration {
    @ObservationIgnored private let defaults: UserDefaults
    var localOnly: Bool { didSet { defaults.set(localOnly, forKey: "ai.localOnly") } }
    var ollamaAddress: String {
        didSet { defaults.set(ollamaAddress, forKey: "ai.ollama.address"); models = [] }
    }
    var llamaCppAddress: String {
        didSet { defaults.set(llamaCppAddress, forKey: "ai.llamaCpp.address") }
    }
    var llamaCppModel: String {
        didSet { defaults.set(llamaCppModel, forKey: "ai.llamaCpp.model") }
    }
    var contextTokens: Int { didSet { defaults.set(contextTokens, forKey: "ai.ollama.context") } }
    var summaryModel: String { didSet { defaults.set(summaryModel, forKey: "ai.ollama.summaryModel") } }
    var chatModel: String { didSet { defaults.set(chatModel, forKey: "ai.ollama.chatModel") } }
    var whisperModel: String { didSet { defaults.set(whisperModel, forKey: "ai.whisper.model") } }
    var whisperLanguage: String { didSet { defaults.set(whisperLanguage, forKey: "ai.whisper.language") } }
    var models: [OllamaModelDescriptor] = []
    var policy: LocalAIPrivacyPolicy { .init(localOnly: localOnly) }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        localOnly = defaults.bool(forKey: "ai.localOnly")
        ollamaAddress = defaults.string(forKey: "ai.ollama.address") ?? "http://localhost:11434"
        llamaCppAddress = defaults.string(forKey: "ai.llamaCpp.address") ?? "http://localhost:8080"
        llamaCppModel = defaults.string(forKey: "ai.llamaCpp.model") ?? "local-model"
        let savedContext = defaults.integer(forKey: "ai.ollama.context")
        contextTokens = savedContext > 0 ? savedContext : 16_384
        summaryModel = defaults.string(forKey: "ai.ollama.summaryModel") ?? ""
        chatModel = defaults.string(forKey: "ai.ollama.chatModel") ?? ""
        whisperModel = defaults.string(forKey: "ai.whisper.model") ?? Self.defaultWhisperModel
        whisperLanguage = defaults.string(forKey: "ai.whisper.language") ?? ""
    }
    private static var defaultWhisperModel: String {
#if os(iOS)
        "openai_whisper-tiny"
#else
        "openai_whisper-small"
#endif
    }
    func capabilities(model: String) -> LLMModelCapabilities {
        models.first { $0.id == model }?.capabilities(contextLimit: contextTokens)
            ?? OllamaModelDescriptor(id: model, size: nil, vision: false, contextWindow: nil).capabilities(contextLimit: contextTokens)
    }
}
