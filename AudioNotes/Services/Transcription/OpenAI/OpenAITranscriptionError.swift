import Foundation

enum OpenAITranscriptionError: Error, LocalizedError, Equatable {
    case missingAPIKey, invalidAuthentication, accessDenied
    case audioUnavailable, unsupportedAudio, emptyAudio, fileTooLarge(limit: Int)
    case rateLimited, quotaExceeded, creditBalanceExhausted, organizationSpendLimit, projectSpendLimit, organizationUsageLimit
    case network(code: Int)
    case server(status: Int)
    case rejected(status: Int)
    case invalidResponse, noSpeech

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an OpenAI API key in Settings → AI Providers before transcribing."
        case .invalidAuthentication: "OpenAI rejected the API key. Update it in Settings → AI Providers."
        case .accessDenied: "This OpenAI key does not have access to transcription. Check its project permissions."
        case .audioUnavailable: "The managed audio file is missing or unreadable. Import the recording again."
        case .unsupportedAudio: "This format cannot be sent to OpenAI. Import a FLAC, MP3, MP4, MPEG, MPGA, M4A, OGG, WAV, or WebM file."
        case .emptyAudio: "The audio file is empty or contains no readable audio."
        case .fileTooLarge(let limit): "An audio part is still larger than OpenAI’s \(limit / 1_000_000) MB upload limit. Try a shorter or more compressed recording."
        case .rateLimited: "OpenAI rate-limited this request. Wait before retrying. If this repeats, check your API project’s rate limits."
        case .quotaExceeded: "Your OpenAI API quota is exhausted. Check API billing and project limits before retrying."
        case .creditBalanceExhausted: "Your OpenAI API credit balance is exhausted. Add API credits before retrying."
        case .organizationSpendLimit: "Your OpenAI organization has reached its API spend limit. Review the organization limit before retrying."
        case .projectSpendLimit: "Your OpenAI project has reached its API spend limit. Review the project limit before retrying."
        case .organizationUsageLimit: "Your OpenAI organization has reached its approved API usage limit. Request a higher limit or wait for it to reset."
        case .network(let code) where code == URLError.timedOut.rawValue: "The transcription request timed out. Check your connection and try again."
        case .network: "Could not connect to OpenAI. Check your internet connection and try again."
        case .server: "OpenAI is temporarily unavailable. Please try again later."
        case .rejected: "OpenAI could not accept this transcription request. Check the file and provider configuration."
        case .invalidResponse: "OpenAI returned an invalid transcript. No transcript was saved. Please try again."
        case .noSpeech: "No speech was returned for this recording. No transcript was saved."
        }
    }
}
