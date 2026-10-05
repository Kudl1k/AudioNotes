import Foundation
import Observation

@MainActor
@Observable
final class RecordingViewModel {
    @ObservationIgnored private var lastGeneration: GenerationRecord?
    var selectedProvider: TranscriptionProviderID? {
        didSet { if selectedProvider != oldValue { selectedModel = nil } }
    }
    var selectedLanguage: TranscriptionLanguage?
    var selectedModel: String?
    var availableModels: [GenerationModelOption] {
        let provider = selectedProvider ?? resolvedProvider.providerID.flatMap(TranscriptionProviderID.init(rawValue:))
        return provider.map { resolver.models(for: $0) } ?? []
    }
    private var resolvedProvider: any TranscriptionProvider { resolver.resolve(provider: selectedProvider, model: selectedModel, language: selectedLanguage) }
    let recording: Recording
    private(set) var state: TranscriptionState
    private(set) var progress: Double?
    private(set) var progressSnapshot: TranscriptionProgressSnapshot?
    private(set) var completedDuration: TimeInterval?
    private(set) var errorDetails: String?
    @ObservationIgnored private let resolver: any TranscriptionProviderResolving
    private var activeProvider: (any TranscriptionProvider)?
    @ObservationIgnored private let storage: LibraryStorage
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attemptID: UUID?
    @ObservationIgnored private var monotonicStart: ContinuousClock.Instant?
    private var progressTracker: TranscriptionProgressTracker?

    init(recording: Recording, provider: any TranscriptionProvider = MockTranscriptionProvider(),
         storage: LibraryStorage = LibraryStorage()) {
        self.recording = recording
        self.resolver = FixedTranscriptionProviderResolver(provider: provider)
        self.storage = storage
        state = recording.transcript == nil ? .idle : .completed
    }

    init(recording: Recording, resolver: any TranscriptionProviderResolving, storage: LibraryStorage = LibraryStorage()) {
        self.recording = recording
        self.resolver = resolver
        self.storage = storage
        state = recording.transcript == nil ? .idle : .completed
    }

    var audioURL: URL { storage.recordingURL(fileName: recording.audioFileName) }
    var executionLocation: ProviderExecutionLocation { (activeProvider ?? resolvedProvider).executionLocation }
    var selectedModelName: String? { (activeProvider ?? resolvedProvider).modelDisplayName }
    var providerName: String { (activeProvider ?? resolvedProvider).displayName }
    var isMockProvider: Bool { (activeProvider ?? resolvedProvider).isMock }
    var transcriptionEstimate: TranscriptionCostEstimate {
        let provider = resolvedProvider
        let size = try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return CostEstimator().transcription(provider: provider.providerID, model: provider.modelID,
            authentication: provider.authenticationMethod, duration: recording.duration, fileSize: size, billingOverride: provider.billingKind)
    }
    var canTranscribe: Bool { !recording.audioFileName.isEmpty && recording.transcript == nil && !state.isProcessing }
    var canRegenerate: Bool { !recording.audioFileName.isEmpty && recording.transcript != nil && !state.isProcessing }
    var elapsedTime: TimeInterval? {
        guard let monotonicStart else { return nil }
        let components = monotonicStart.duration(to: ContinuousClock.now).components
        return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }
    var completionDurationText: String { OperationDurationFormatter.string(completedDuration ?? 0) }
    var showsCompletion: Bool { completedDuration != nil }

    /// The view model owns task lifetime; returning the task permits deterministic tests.
    @discardableResult
    func startTranscription(using repository: any TranscriptStoring, replacingExisting: Bool = false) -> Task<Void, Never>? {
        guard replacingExisting ? canRegenerate : canTranscribe else { return nil }
        let provider = resolvedProvider
        activeProvider = provider
        let id = UUID()
        attemptID = id
        errorDetails = nil
        state = .preparing
        progress = nil
        let startedAt = Date.now
        let generation: GenerationRecord
        if let previous = lastGeneration, previous.canRetry(provider: provider.providerID, model: provider.modelID, authentication: provider.authenticationMethod) {
            generation = previous
            generation.attemptCount += 1
            generation.statusRaw = GenerationStatus.inProgress.rawValue
            generation.errorCategory = nil
        } else {
            generation = GenerationRecord(recording: recording, feature: .transcription, startedAt: startedAt,
            provider: provider.providerID.flatMap(LLMProviderID.init(rawValue:)), model: provider.modelID,
            presetName: nil, outputLength: .medium, settings: nil,
            authenticationMethod: provider.authenticationMethod, status: .inProgress, billingKind: provider.billingKind)
            generation.providerIDRaw = provider.providerID
        }
        lastGeneration = generation
        generation.executionLocationRaw = provider.executionLocation.rawValue
        generation.modelDisplayNameSnapshot = provider.modelDisplayName
        generation.estimatedCostData = try? JSONEncoder().encode(transcriptionEstimate.cost)
        let tracker = OperationUsageTracker(generation: generation) { try? repository.record(generation) }
        var requestIDs: [UUID: UUID] = [:]
        try? repository.record(generation)
        monotonicStart = ContinuousClock.now
        progressTracker = TranscriptionProgressTracker(startedAt: startedAt, totalAudioDuration: recording.duration)
        progressSnapshot = progressTracker?.snapshot
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation.statusRaw == GenerationStatus.inProgress.rawValue {
                    tracker.finish(status: Task.isCancelled ? .cancelled : .failed)
                }
                try? repository.record(generation)
                if self.attemptID == id {
                    self.activeProvider = nil
                    self.task = nil
                    self.attemptID = nil
                }
            }
            do {
                try Task.checkCancellation()
                guard FileManager.default.isReadableFile(atPath: self.audioURL.path) else {
                    throw TranscriptionError.audioUnavailable
                }
                self.state = .transcribing
                self.progressTracker?.setPhase(.preparing)
                self.progressSnapshot = self.progressTracker?.snapshot
                let transcript = try await provider.transcribe(audioURL: self.audioURL, progress: { [weak self] fraction in
                    guard let self, self.attemptID == id, self.state == .transcribing else { return }
                    self.progress = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
                }, status: { [weak self] update in
                    guard let self, self.attemptID == id else { return }
                    if update.phase == .transcribing { self.state = .transcribing }
                    self.progressTracker?.apply(update, elapsed: self.elapsedTime ?? 0)
                    self.progressSnapshot = self.progressTracker?.snapshot
                }, usage: { event in
                    switch event {
                    case .began(let externalID): requestIDs[externalID] = tracker.beginRequest()
                    case .finished(let externalID, let usage, let succeeded):
                        if let requestID = requestIDs.removeValue(forKey: externalID) {
                            tracker.finishRequest(requestID, transcription: usage, succeeded: succeeded)
                        }
                    }
                })
                // Even providers that finish after cancellation cannot save stale results.
                try Task.checkCancellation()
                guard self.attemptID == id else { return }
                if self.progressTracker?.snapshot.completedParts == 0 {
                    self.progressTracker?.completePart(audioDuration: self.recording.duration, atElapsed: self.elapsedTime ?? 0)
                }
                self.progressTracker?.setPhase(.saving)
                self.progressSnapshot = self.progressTracker?.snapshot
                self.state = .saving
                self.progress = nil
                transcript.sourceName = provider.displayName
                transcript.isMock = provider.isMock
                transcript.generationID = generation.id
                try repository.save(transcript, for: self.recording)
                self.progress = 1
                self.progressTracker?.setPhase(.completed)
                self.progressSnapshot = self.progressTracker?.snapshot
                self.completedDuration = self.elapsedTime
                tracker.finish(status: .succeeded)
                self.state = .completed
            } catch {
                guard self.attemptID == id else { return }
                self.progress = nil
                if Task.isCancelled || error is CancellationError {
                    self.state = .cancelled
                } else {
                    self.errorDetails = (error as? any TranscriptionDiagnosticError)?.diagnosticDetails
                    self.state = .failed(message: error.localizedDescription)
                }
            }
        }
        return task
    }

    func cancelTranscription() {
        guard state.canCancel else { return }
        task?.cancel()
        activeProvider = nil
        task = nil
        attemptID = nil
        progress = nil
        progressSnapshot = nil
        completedDuration = nil
        progressTracker = nil
        monotonicStart = nil
        errorDetails = nil
        state = .cancelled
    }

    func dismissCompletion() {
        guard state == .completed else { return }
        completedDuration = nil
        progressSnapshot = nil
        progressTracker = nil
        monotonicStart = nil
    }
}
