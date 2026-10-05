import Foundation

/// Progress is a fraction in 0...1, or nil when the provider cannot estimate it.
/// Worker actors can report progress by awaiting this main-actor callback.
typealias TranscriptionProgress = @MainActor @Sendable (Double?) -> Void
typealias TranscriptionStatusReporter = @MainActor @Sendable (TranscriptionStatus) -> Void

struct TranscriptionStatus: Sendable {
    var phase: TranscriptionPhase
    var currentPart: Int?
    var totalParts: Int?
    var completedParts: Int
    var processedAudioDuration: TimeInterval
    var totalAudioDuration: TimeInterval
}

struct TranscriptionProviderCapabilities: Equatable, Sendable {
    var maxDirectUploadSize: Int64?
    var maxProviderFileUploadSize: Int64?
    var supportsProviderFileUpload: Bool
    var supportsTimestamps: Bool
    var supportsDiarization: Bool
    var maximumDuration: TimeInterval?
    var requiresChunking: Bool
}

/// Returns a new, unpersisted model graph. SwiftData objects never cross actors.
/// This main-actor entry point orchestrates async work; implementations must run
/// decoding/inference in a worker actor and network requests asynchronously.
/// Providers must cooperate with Task cancellation and must not persist results.
@MainActor
protocol TranscriptionProvider {
    var displayName: String { get }
    var executionLocation: ProviderExecutionLocation { get }
    var isMock: Bool { get }
    var providerID: String? { get }
    var billingKind: BillingKind { get }
    var modelID: String? { get }
    var modelDisplayName: String? { get }
    var capabilities: TranscriptionProviderCapabilities { get }
    var authenticationMethod: ProviderAuthenticationMethod? { get }
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress,
                    status: @escaping TranscriptionStatusReporter,
                    usage: @escaping @MainActor (TranscriptionRequestEvent) -> Void) async throws -> Transcript

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress,
                    status: @escaping TranscriptionStatusReporter) async throws -> Transcript
}

extension TranscriptionProvider {
    var isMock: Bool { false }
    var executionLocation: ProviderExecutionLocation { isMock ? .local : .cloud }
    var providerID: String? { isMock ? "mock" : nil }
    var billingKind: BillingKind { isMock ? .local : BillingKind.resolve(provider: providerID, authentication: authenticationMethod) }
    var modelID: String? { nil }
    var modelDisplayName: String? { modelID }
    var capabilities: TranscriptionProviderCapabilities {
        .init(maxDirectUploadSize: nil, maxProviderFileUploadSize: nil, supportsProviderFileUpload: false, supportsTimestamps: false,
              supportsDiarization: false, maximumDuration: nil, requiresChunking: false)
    }
    var authenticationMethod: ProviderAuthenticationMethod? { nil }

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress,
                    status: @escaping TranscriptionStatusReporter,
                    usage: @escaping @MainActor (TranscriptionRequestEvent) -> Void) async throws -> Transcript {
        let id = UUID()
        usage(.began(id))
        do {
            let result = try await transcribe(audioURL: audioURL, progress: progress, status: status)
            usage(.finished(id, nil, true))
            return result
        } catch {
            usage(.finished(id, nil, false))
            throw error
        }
    }

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress,
                    status: @escaping TranscriptionStatusReporter) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress)
    }
}

enum TranscriptionError: LocalizedError {
    case audioUnavailable
    case invalidAudio
    case invalidTranscript
    case transcriptAlreadyExists

    var errorDescription: String? {
        switch self {
        case .audioUnavailable: "The imported audio file is no longer available. Import the recording again."
        case .invalidAudio: "The recording does not contain readable audio."
        case .invalidTranscript: "The provider returned an empty transcript or invalid timestamps. Please try again."
        case .transcriptAlreadyExists: "This recording already has a transcript."
        }
    }
}


enum TranscriptionRequestEvent {
    case began(UUID)
    case finished(UUID, TranscriptionUsage?, Bool)
}
