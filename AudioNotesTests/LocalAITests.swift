import Foundation
import SwiftData
import Testing
import Synchronization
@testable import AudioNotes

@MainActor struct LocalAITests {
    private func configuration() -> LocalAIConfiguration {
        LocalAIConfiguration(defaults: UserDefaults(suiteName: "LocalAI-" + UUID().uuidString)!)
    }
    @Test func exactLoopbackOnlyAndEndpointValidation() throws {
        for address in ["localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434"] {
            #expect(try OllamaEndpoint(address).executionLocation == .local)
        }
        for address in ["http://localhost.example:11434", "http://192.168.1.2:11434", "https://ollama.com", "http://127.0.0.2:11434"] {
            #expect(try OllamaEndpoint(address).executionLocation == .remote)
        }
        for address in ["file:///tmp/model", "http://key@localhost:11434", "http://localhost:11434/api", "http://localhost:11434?secret=x"] {
            #expect(throws: LocalAIError.invalidEndpoint) { try OllamaEndpoint(address) }
        }
    }
    @Test func privacyBlocksAllExternalLocations() throws {
        let policy = LocalAIPrivacyPolicy(localOnly: true)
        try policy.validate(.local)
        for location in [ProviderExecutionLocation.cloud, .remote] {
            #expect(throws: LocalAIError.privacyBlocked) { try policy.validate(location) }
        }
        try LocalAIPrivacyPolicy(localOnly: false).validate(.remote)
    }
    @Test func privacyGateRechecksAtExecutionAndNeverCallsCloud() async throws {
        let config = configuration()
        let spy = PrivacySpyLLM()
        let gated = PrivacyLLMProvider(base: spy, configuration: config)
        config.localOnly = true
        await #expect(throws: LocalAIError.privacyBlocked) { _ = try await gated.generateSummary(transcript: Transcript(), configuration: .init()) }
        await #expect(throws: LocalAIError.privacyBlocked) { try await gated.streamChat(messages: [], context: .init(recordingTitle: "", transcript: Transcript())) }
        await #expect(throws: LocalAIError.privacyBlocked) { _ = try await gated.generateSourceSummary(context: .init(chunks: []), configuration: .init()) }
        #expect(spy.calls == 0)
        config.localOnly = false
        _ = try await gated.generateSummary(transcript: Transcript(), configuration: .init())
        #expect(spy.calls == 1)
    }
    @Test func transcriptionGateDoesNotInvokeCloudRuntime() async throws {
        let config = configuration(); config.localOnly = true
        let spy = PrivacySpyTranscription()
        let gated = PrivacyTranscriptionProvider(base: spy, configuration: config)
        await #expect(throws: LocalAIError.privacyBlocked) { _ = try await gated.transcribe(audioURL: URL(filePath: "/fake"), progress: { _ in }) }
        #expect(spy.calls == 0)
    }
    @Test func selectedModelsAndPrivacyPersistWithoutFallback() {
        let defaults = UserDefaults(suiteName: "local-persistence-" + UUID().uuidString)!
        let first = LocalAIConfiguration(defaults: defaults)
        first.localOnly = true; first.summaryModel = "deleted:model"; first.chatModel = "custom:model"
        first.whisperLanguage = "cs"; first.ollamaAddress = "http://192.168.1.1:9999"
        let second = LocalAIConfiguration(defaults: defaults)
        #expect(second.localOnly)
        #expect(second.summaryModel == "deleted:model")
        #expect(second.chatModel == "custom:model")
        #expect(second.whisperLanguage == "cs")
        #expect(second.ollamaAddress == first.ollamaAddress)
        #expect(second.models.isEmpty)
    }
    @Test func localAndRemoteOllamaBillingIsSeparateFromMeteredAPI() throws {
        let config = configuration()
        let local = OllamaLLMProvider(model: "test", configuration: config)
        #expect(local.billingKind == .local)
        #expect(CostCalculator().calculate(pricing: nil, billing: local.billingKind).displayText == "Local · No API charge")
        config.ollamaAddress = "http://192.168.1.2:11434"
        let remote = OllamaLLMProvider(model: "test", configuration: config)
        #expect(remote.billingKind == .unknown)
        #expect(remote.executionLocation == .remote)
        #expect(CostCalculator().calculate(pricing: nil, billing: remote.billingKind).amount == nil)
    }
    @Test func localHistoryReopensWithReadableMetadataAndCascadesOnDeletion() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        do {
            let container = try workspace.storage.makeContainer()
            let context = ModelContext(container)
            let recording = try multiSourceFixture()
            context.insert(recording)
            let record = GenerationRecord(recording: recording, feature: .transcription, provider: nil,
                model: "openai_whisper-small", presetName: nil, outputLength: .medium, settings: nil, billingKind: .local)
            record.providerIDRaw = "localWhisper"
            record.executionLocationRaw = ProviderExecutionLocation.local.rawValue
            record.modelDisplayNameSnapshot = "Small"
            let tracker = OperationUsageTracker(generation: record)
            tracker.finishRequest(tracker.beginRequest(), succeeded: true)
            tracker.finish(status: .succeeded)
            context.insert(record); try context.save()
        }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let record = try #require(context.fetch(FetchDescriptor<GenerationRecord>()).first)
        #expect(record.executionLocationRaw == "local")
        #expect(record.billingKind == .local)
        #expect(record.usageDetails.contains("Local Whisper"))
        #expect(record.usageDetails.contains("Small"))
        #expect(!record.usageDetails.contains("openai_whisper-small"))
        let recording = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        context.delete(recording); try context.save()
        #expect(try context.fetch(FetchDescriptor<GenerationRecord>()).isEmpty)
    }

    @Test func modelCatalogContainsPinnedIntegrityAndMultipleMultilingualSizes() throws {
        let catalog = WhisperModelDescriptor.bundled
        #expect(catalog.count == 5)
        for model in catalog {
            #expect(model.downloadBytes > 0)
            #expect(model.files.allSatisfy { $0.sha256?.count == 64 && $0.url.scheme == "https" })
            #expect(model.files.contains { $0.path == "tokenizer.json" })
            #expect(model.files.contains { $0.path == "tokenizer_config.json" })
        }
    }
    @Test func localProgressUsesMeasuredAudioAndSmoothedETA() {
        var tracker = TranscriptionProgressTracker(startedAt: .now, totalAudioDuration: 3600)
        tracker.apply(.init(phase: .transcribing, completedParts: 0, processedAudioDuration: 120, totalAudioDuration: 3600), elapsed: 12)
        #expect(tracker.snapshot.overallProgress == 120.0 / 3600)
        #expect(tracker.snapshot.completedParts == 0)
        #expect(tracker.snapshot.estimatedRemainingTime == 348)
        tracker.apply(.init(phase: .transcribing, completedParts: 0, processedAudioDuration: 240, totalAudioDuration: 3600), elapsed: 24)
        #expect(tracker.snapshot.estimatedRemainingTime == 336)
    }
    @Test func whisperTranscriptValidatesOriginalTimestampsAndLanguage() throws {
        for language in ["cs", "en"] {
            let transcript = try LocalWhisperTranscriptionProvider.makeTranscript(.init(language: language, segments: [
                .init(start: 120, end: 123, text: "Next inference window"), .init(start: 0, end: 1, text: "Hello")]), model: "Small")
            #expect(transcript.languageCode == language)
            #expect(transcript.segmentSnapshots.map(\.startTime) == [0, 120])
            #expect(!transcript.isMock)
        }
        #expect(throws: TranscriptionError.self) {
            try LocalWhisperTranscriptionProvider.makeTranscript(.init(language: nil, segments: [.init(start: -.infinity, end: 3, text: "bad")]), model: "Small")
        }
    }
    @Test func missingWhisperModelDoesNotCallRuntime() async throws {
        let model = WhisperModelDescriptor(id: "missing", title: "Missing", files: [])
        let store = WhisperModelStore(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let runtime = WhisperRuntimeSpy()
        let provider = LocalWhisperTranscriptionProvider(model: model, language: "cs", runtime: runtime, store: store)
        await #expect(throws: LocalAIError.missingModel("Missing")) { _ = try await provider.transcribe(audioURL: URL(filePath: "/fake"), progress: { _ in }) }
        #expect(await runtime.calls == 0)
        try await store.acquire(); await store.release()
    }
    @Test func modelLeaseProtectsDeletionAndFailureReleasesResources() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WhisperModelDescriptor(id: "test", title: "Test", files: [])
        let folder = root.appendingPathComponent("test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".ready"))
        let store = WhisperModelStore(root: root)
        #expect(await store.isReady(model))
        try await store.acquire()
        await #expect(throws: LocalAIError.modelBusy) { try await store.remove(model) }
        await store.release()
        let runtime = WhisperRuntimeSpy(fails: true)
        let provider = LocalWhisperTranscriptionProvider(model: model, language: nil, runtime: runtime, store: store)
        await #expect(throws: LocalAIError.invalidResponse) { _ = try await provider.transcribe(audioURL: URL(filePath: "/fake"), progress: { _ in }) }
        #expect(await runtime.calls == 1)
        try await store.remove(model)
        #expect(await store.isReady(model) == false)
    }
    @Test func modelDownloadDoesNotAcceptPartialFiles() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".ready"))
        let model = WhisperModelDescriptor(id: "test", title: "Test", files: [.init(path: "model", url: URL(string: "https://huggingface.co/test")!, size: 10, sha256: nil)])
        let store = WhisperModelStore(root: root)
        #expect(await store.isReady(model) == false)
        #expect(try WhisperModelStore.hash(folder.appendingPathComponent(".ready")) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}

@MainActor private final class PrivacySpyLLM: LLMProvider {
    let id: LLMProviderID = .openAI
    let displayName = "Cloud spy"
    var calls = 0
    func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary { calls += 1; return Summary(overview: "Test") }
    func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary { calls += 1; return Summary(overview: "Test") }
    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> { calls += 1; return AsyncThrowingStream { $0.finish() } }
}
@MainActor private final class PrivacySpyTranscription: TranscriptionProvider {
    let displayName = "Cloud spy"
    var calls = 0
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript { calls += 1; return Transcript() }
}
private actor WhisperRuntimeSpy: LocalWhisperRunning {
    var calls = 0
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func transcribe(audioURL: URL, modelFolder: URL, language: String?, status: @escaping LocalWhisperStatusReporter) async throws -> LocalWhisperResult {
        calls += 1
        if fails { throw LocalAIError.invalidResponse }
        await status(120, 120)
        return .init(language: language, segments: [.init(start: 0, end: 120, text: "Local result")])
    }
}
