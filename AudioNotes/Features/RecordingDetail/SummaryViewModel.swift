import Foundation
import Observation

@MainActor
@Observable
final class SummaryViewModel {
    @ObservationIgnored private var lastGeneration: GenerationRecord?
    var selectedProvider: LLMProviderID? {
        didSet { if selectedProvider != oldValue { selectedModel = nil } }
    }
    var selectedModel: String?
    var availableModels: [GenerationModelOption] { resolver.summaryModels(for: resolvedProvider.id) }
    private var resolvedProvider: any LLMProvider {
        resolver.resolveSummary(provider: selectedProvider ?? selectedUserPreset?.provider,
            model: selectedModel ?? (selectedProvider == nil ? selectedUserPreset?.model : nil))
    }
    var selectedModelName: String? { (activeProvider ?? resolvedProvider).modelID }
    let recording: Recording
    private(set) var state: SummaryState
    var selectedSourceIDs: Set<UUID>? = nil
    var allowImageUpload = false
    var executionDescription: String { (activeProvider ?? resolvedProvider).executionLocation.title }
    var supportsImageInput: Bool { resolvedProvider.inputCapabilities.supportsImageInput }
    var usesUnifiedContext: Bool { (!recording.sources.isEmpty && resolvedProvider.supportsSourceSummaries) || recording.sources.contains { !$0.isPrimaryAudio } || selectedSourceIDs != nil || recording.transcript == nil }
    var hasReadySources: Bool { RecordingContextAvailability.hasContent(recording) }
    var selectedPreset: SummaryPreset
    var customInstructions: String = ""
    var selectedUserPreset: AIPreset?
    var generationSettings: LLMGenerationSettings?
    var outputLength: OutputLength = .medium
    private(set) var progressMessage: String?

    @ObservationIgnored private let resolver: any LLMProviderResolving
    @ObservationIgnored private var activeProvider: (any LLMProvider)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attemptID: UUID?

    init(
        recording: Recording,
        resolver: any LLMProviderResolving,
        defaultPreset: SummaryPreset = .general
    ) {
        self.recording = recording
        self.resolver = resolver
        self.generationSettings = resolver.summarySettings()
        self.outputLength = recording.summary?.outputLength ?? resolver.summarySettings().outputLength
        self.selectedPreset = recording.summary?.preset ?? defaultPreset
        self.state = recording.summary == nil ? .idle : .completed
    }

    var costEstimate: EstimatedCostRange? {
        let provider = resolvedProvider
        guard BillingKind.resolve(provider: provider.id.rawValue, authentication: provider.authenticationMethod) == .meteredAPI else { return nil }
        if usesUnifiedContext {
            guard !allowImageUpload else { return nil }
            let context = SourceSummaryContext(chunks: RecordingContextSnapshot(recording: recording, selectedSourceIDs: selectedSourceIDs).chunks)
            guard context.approximateTokens <= 32_000, let prompt = try? context.prompt(configuration: SummaryConfiguration(preset: selectedPreset, customInstructions: customInstructions, outputLength: outputLength)),
                  BillingKind.resolve(provider: provider.id.rawValue, authentication: provider.authenticationMethod) == .meteredAPI, let model = provider.modelID else { return nil }
            return CostEstimator().llmBudget(provider: provider.id.rawValue, model: model, operation: .summary, approximateInputTokens: TranscriptTokenEstimator.estimate(prompt.systemMessage + prompt.userMessage), outputTokenCeiling: generationSettings?.maxOutputTokens)
        }
        guard BillingKind.resolve(provider: provider.id.rawValue, authentication: provider.authenticationMethod) == .meteredAPI,
              let model = provider.modelID, let transcript = recording.transcript,
              let context = try? SummaryPromptBuilder().formatTranscript(transcript),
              context.approximateTokens <= 32_000 else { return nil }
        var settings = generationSettings ?? resolver.summarySettings()
        settings.outputLength = outputLength
        let configuration = SummaryConfiguration(preset: selectedPreset, customInstructions: customInstructions,
            generationSettings: settings, outputLength: outputLength)
        let prompt = SummaryPromptBuilder().buildPrompt(transcriptContext: context, configuration: configuration)
        let tokens = TranscriptTokenEstimator.estimate(prompt.systemMessage + prompt.userMessage)
        return CostEstimator().llmBudget(provider: provider.id.rawValue, model: model, operation: .summary,
            approximateInputTokens: tokens, outputTokenCeiling: settings.maxOutputTokens)
    }

    var providerName: String {
        (activeProvider ?? resolvedProvider).displayName
    }

    var isMockProvider: Bool {
        (activeProvider ?? resolvedProvider).isMock
    }

    var canGenerate: Bool {
        RecordingContextAvailability.hasContent(recording, selectedSourceIDs: selectedSourceIDs) && !state.isGenerating
    }

    func applyUserPreset(_ preset: AIPreset) {
        selectedProvider = nil
        selectedModel = nil
        selectedUserPreset = preset
        selectedPreset = preset.basePreset ?? .general
        customInstructions = preset.userInstructions ?? ""
        generationSettings = preset.generationSettings
        outputLength = preset.generationSettings.outputLength
    }

    func selectBuiltInPreset(_ preset: SummaryPreset) {
        selectedUserPreset = nil
        selectedPreset = preset
        if preset != .custom {
            customInstructions = ""
        }
    }

    @discardableResult
    func generateSummary(
        using repository: any SummaryStoring,
        presetOverride: SummaryPreset? = nil
    ) -> Task<Void, Never>? {
        guard canGenerate else { return nil }
        let transcript = recording.transcript ?? Transcript()
        let unified = usesUnifiedContext || resolvedProvider.inputCapabilities.contextWindowTokens < 100_000
        let sourceSelection = selectedSourceIDs
        let imagePermission = allowImageUpload

        let presetToUse = presetOverride ?? selectedPreset
        selectedPreset = presetToUse

        let provider = resolvedProvider
        activeProvider = provider
        let id = UUID()
        attemptID = id
        state = .generating
        let startedAt = Date.now

        var effectiveSettings = generationSettings ?? resolver.summarySettings()
        effectiveSettings.outputLength = outputLength
        let config = SummaryConfiguration(
            preset: presetToUse,
            customInstructions: customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customInstructions,
            providerID: provider.id,
            generationSettings: effectiveSettings,
            outputLength: outputLength
        )
        let presetNameSnapshot = selectedUserPreset?.name ?? presetToUse.title
        let selectionData = try? JSONEncoder().encode(Array(RecordingContextAvailability.readySourceIDs(recording, selectedSourceIDs: sourceSelection)).sorted { $0.uuidString < $1.uuidString })
        let generation: GenerationRecord
        if let previous = lastGeneration, previous.selectedSourceIDsData == selectionData, previous.presetName == presetNameSnapshot, previous.outputLengthRaw == config.outputLength.rawValue, previous.canRetry(provider: provider.id.rawValue, model: provider.modelID, authentication: provider.authenticationMethod) {
            generation = previous
            generation.attemptCount += 1
            generation.statusRaw = GenerationStatus.inProgress.rawValue
            generation.errorCategory = nil
        } else {
            generation = GenerationRecord(recording: recording, feature: .summary, startedAt: startedAt,
            provider: provider.id, model: provider.modelID, presetName: presetNameSnapshot,
            outputLength: config.outputLength, settings: config.generationSettings,
            authenticationMethod: provider.authenticationMethod, status: .inProgress, billingKind: provider.billingKind)
        }
        generation.estimatedCostRangeData = costEstimate.flatMap { try? JSONEncoder().encode($0) }
        generation.selectedSourceIDsData = selectionData
        generation.executionLocationRaw = provider.executionLocation.rawValue
        lastGeneration = generation
        let tracker = OperationUsageTracker(generation: generation) { try? repository.record(generation) }
        let trackedProvider = UsageTrackingLLMProvider(base: provider, tracker: tracker)
        try? repository.record(generation)

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
                let result: HierarchicalSummaryResult
                if unified {
                    let context = try await SourceContextPreparation().prepareSummary(recording: self.recording, selectedSourceIDs: sourceSelection,
                        provider: provider, allowImages: imagePermission)
                    result = try await HierarchicalSummaryGenerator().generate(context: context, configuration: config, provider: trackedProvider) { message in
                        self.progressMessage = message.isEmpty ? nil : message
                    }
                    result.summary.sourceReferences = SourceReferenceResolver().validate(result.summary.sourceReferences, recording: self.recording)
                } else {
                    result = try await HierarchicalSummaryGenerator().generate(transcript: transcript, configuration: config, provider: trackedProvider) { message in
                        self.progressMessage = message.isEmpty ? nil : message
                    }
                }
                let newSummary = result.summary

                try Task.checkCancellation()
                guard self.attemptID == id else { return }

                newSummary.outputLength = config.outputLength
                newSummary.generationID = generation.id
                try repository.save(newSummary, for: self.recording)
                generation.summaryID = newSummary.id
                let text = newSummary.overview + newSummary.keyPoints.map(\.text).joined(separator: " ")
                generation.characterCount = text.count
                generation.wordCount = text.split(whereSeparator: \.isWhitespace).count
                generation.generationStrategy = result.chunkCount > 1 ? "hierarchical" : "single_pass"
                generation.chunkCount = result.chunkCount
                tracker.finish(status: .succeeded)
                try repository.record(generation)
                self.state = .completed
                self.progressMessage = nil
            } catch is CancellationError {
                guard self.attemptID == id else { return }
                self.state = .idle
                self.progressMessage = nil
            } catch let error as LLMError {
                guard self.attemptID == id else { return }
                self.state = .failed(message: error.localizedDescription)
                self.progressMessage = nil
                tracker.finish(status: .failed)
                generation.errorCategory = "provider_error"
                try? repository.record(generation)
            } catch {
                guard self.attemptID == id else { return }
                self.state = .failed(message: error.localizedDescription)
                self.progressMessage = nil
                tracker.finish(status: .failed)
                generation.errorCategory = "provider_error"
                try? repository.record(generation)
            }
        }

        return task
    }

    /// A failed version-history change; shown by whichever view started it.
    var historyError: String?

    /// Restores a previous version as current. Returns whether it succeeded.
    @discardableResult
    func makeCurrent(_ summary: Summary, using repository: any SummaryStoring) -> Bool {
        do {
            try repository.makeCurrent(summary, for: recording)
            return true
        } catch {
            historyError = "This summary version could not be made current. Try again."
            return false
        }
    }

    /// Deletes a non-current version. Returns whether it succeeded.
    @discardableResult
    func deleteVersion(_ summary: Summary, using repository: any SummaryStoring) -> Bool {
        do {
            try repository.delete(summary, for: recording)
            return true
        } catch {
            historyError = "This summary version could not be deleted. Nothing was removed."
            return false
        }
    }

    func cancelGeneration() {
        attemptID = nil
        task?.cancel()
        task = nil
        activeProvider = nil
        progressMessage = nil
        if state.isGenerating {
            state = recording.summary == nil ? .idle : .completed
        }
    }
}
