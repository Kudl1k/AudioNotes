import Foundation
import Observation

enum TranscriptionProviderID: String, CaseIterable, Identifiable, Sendable {
    case mock, openAI, localWhisper
    var id: Self { self }
    var title: String { switch self { case .mock: "Mock (development)"; case .openAI: "OpenAI"; case .localWhisper: "Local Whisper" } }
}

public struct OpenAITranscriptionModel: RawRepresentable, Hashable, Identifiable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }

    public static let whisper1 = OpenAITranscriptionModel(rawValue: "whisper-1")
    public static let gpt4oTranscribe = OpenAITranscriptionModel(rawValue: "gpt-4o-transcribe")
    public static let gpt4oMiniTranscribe = OpenAITranscriptionModel(rawValue: "gpt-4o-mini-transcribe")

    public static let standardModels: [OpenAITranscriptionModel] = [
        .whisper1,
        .gpt4oTranscribe,
        .gpt4oMiniTranscribe
    ]

    public static var allCases: [OpenAITranscriptionModel] {
        standardModels
    }

    public var supportsSegmentTimestamps: Bool {
        rawValue.lowercased().hasPrefix("whisper")
    }

    public var title: String {
        switch rawValue {
        case "whisper-1":
            return "Whisper-1 (cloud, segment timestamps)"
        case "gpt-4o-transcribe":
            return "GPT-4o Transcribe (high accuracy)"
        case "gpt-4o-mini-transcribe":
            return "GPT-4o Mini Transcribe (fast & economical)"
        default:
            return rawValue
        }
    }
}

enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic = "", english = "en", czech = "cs", slovak = "sk", german = "de"
    case french = "fr", spanish = "es", italian = "it", portuguese = "pt", polish = "pl"
    case ukrainian = "uk", japanese = "ja", chinese = "zh", korean = "ko", arabic = "ar"
    var id: Self { self }
    var code: String? { self == .automatic ? nil : rawValue }
    var title: String {
        self == .automatic ? "Automatic detection" : Locale.current.localizedString(forLanguageCode: rawValue) ?? rawValue
    }
}

struct OpenAITranscriptionConfiguration: Sendable, Equatable {
    var model: OpenAITranscriptionModel = .whisper1
    var language: TranscriptionLanguage = .automatic
}

/// Contains only non-secret preferences. Invalid/stale values fall back safely.
@MainActor
@Observable
final class TranscriptionConfiguration {
    @ObservationIgnored private let defaults: UserDefaults
    var selectedProvider: TranscriptionProviderID {
        didSet { defaults.set(selectedProvider.rawValue, forKey: "transcription.provider") }
    }
    var openAIModel: OpenAITranscriptionModel {
        didSet { defaults.set(openAIModel.rawValue, forKey: "transcription.openai.model") }
    }
    var language: TranscriptionLanguage {
        didSet { defaults.set(language.rawValue, forKey: "transcription.language") }
    }

    var availableVoiceModels: [OpenAITranscriptionModel] {
        get {
            guard let array = defaults.stringArray(forKey: "transcription.openai.cached_models"), !array.isEmpty else {
                return OpenAITranscriptionModel.standardModels
            }
            return array.map { OpenAITranscriptionModel(rawValue: $0) }
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: "transcription.openai.cached_models")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedProvider = TranscriptionProviderID(rawValue: defaults.string(forKey: "transcription.provider") ?? "") ?? .mock
        let storedModel = defaults.string(forKey: "transcription.openai.model")
        if let storedModel, storedModel != "unknown", !storedModel.isEmpty {
            openAIModel = OpenAITranscriptionModel(rawValue: storedModel)
        } else {
            openAIModel = .whisper1
        }
        language = TranscriptionLanguage(rawValue: defaults.string(forKey: "transcription.language") ?? "") ?? .automatic
    }

    var openAI: OpenAITranscriptionConfiguration { .init(model: openAIModel, language: language) }
}
