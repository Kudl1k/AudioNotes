import Foundation
import SwiftData
import Testing
@testable import AudioNotes

private actor LocalLanguageRuntimeFixture: LocalLLMRunning {
    var requests: [LocalLLMRequest] = []
    var unloads = 0
    let refs: [String]
    let failure: LocalAIError?
    let hold: Bool
    private var worker: Task<Void, Never>?
    init(refs: [String] = [], failure: LocalAIError? = nil, hold: Bool = false) {
        self.refs = refs; self.failure = failure; self.hold = hold
    }
    func cancelAndUnload() async {
        unloads += 1
        let task = worker; worker = nil; task?.cancel(); await task?.value
    }
    func stream(_ request: LocalLLMRequest) throws -> AsyncThrowingStream<LocalLLMEvent, Error> {
        requests.append(request)
        if let failure { throw failure }
        let refs = refs; let hold = hold
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if case .summary = request.kind {
                        let dto = StructuredSummaryResponse(overview: "Local overview", keyPoints: ["Grounded point"], title: "Local summary")
                        continuation.yield(.completedJSON(String(decoding: try JSONEncoder().encode(dto), as: UTF8.self)))
                    } else {
                        continuation.yield(.answerSnapshot("Local "))
                        if hold { try await Task.sleep(for: .seconds(60)) }
                        continuation.yield(.answerSnapshot("Local answer"))
                        let dto = StructuredChatResponse(answer: "Local answer", referenceSegmentIDs: refs)
                        continuation.yield(.completedJSON(String(decoding: try JSONEncoder().encode(dto), as: UTF8.self)))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            worker = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private actor LocalTranscriptionRuntimeFixture: LocalWhisperRunning {
    var calls = 0
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func transcribe(audioURL: URL, modelFolder: URL, language: String?, status: @escaping LocalWhisperStatusReporter) async throws -> LocalWhisperResult {
        calls += 1
        try Task.checkCancellation()
        if fail { throw LocalAIError.inference("Fixture failure") }
        await status(120, 240); await status(240, 240)
        return .init(language: language ?? "cs", segments: [.init(start: 121, end: 123, text: "Local transcript")])
    }
}

@MainActor struct IOSLocalAITests {
    private func recording() -> Recording {
        let recording = Recording(title: "Local fixture", audioFileName: "fixture.wav", originalFileName: "fixture.wav", duration: 240)
        let transcript = Transcript(languageCode: "cs")
        transcript.segments = [.init(position: 0, startTime: 121, endTime: 123, text: "Character device registration cdev_add major minor")]
        recording.transcript = transcript
        return recording
    }
    private func wait(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<500 { if done() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Local operation did not finish")
    }
    @Test func providerCapabilitiesAndPrivacyAreLocal() {
        let provider = LocalLLMProvider(runtime: LocalLanguageRuntimeFixture())
        #expect(provider.id == .onDevice && provider.executionLocation == .local && provider.billingKind == .local)
        #expect(provider.inputCapabilities.contextWindowTokens == 4096)
        #expect(!provider.inputCapabilities.supportsImageInput)
        #expect(throws: Never.self) { try LocalAIPrivacyPolicy(localOnly: true).validate(provider.executionLocation) }
    }
    @Test func unsupportedParametersAreRemovedWithoutChangingSavedPreset() throws {
        let saved = LLMGenerationSettings(maxOutputTokens: 256, temperature: 0.3, topP: 0.8, reasoningEffort: .high, outputLength: .detailed)
        let request = try LocalLLMProvider.request(instructions: "Grounded", messages: [.init(role: .user, content: "Hello")], kind: .chat, settings: saved)
        #expect(request.settings.temperature == 0.3 && request.settings.maxOutputTokens == 256)
        #expect(request.settings.topP == nil && request.settings.reasoningEffort == nil)
        #expect(request.settings.outputLength == .detailed)
        #expect(saved.topP == 0.8 && saved.reasoningEffort == .high)
    }
    @Test func unsupportedModelFailsWithoutSwitchingModels() async throws {
        let runtime = LocalLanguageRuntimeFixture()
        let provider = LocalLLMProvider(runtime: runtime, selectedModel: "unavailable-model")
        await #expect(throws: LocalAIError.self) { try await provider.prepareForGeneration() }
        #expect(provider.modelID == "unavailable-model")
        #expect(await runtime.requests.isEmpty)
    }
    @Test func contextOverflowFailsBeforeRuntime() async throws {
        let runtime = LocalLanguageRuntimeFixture()
        let provider = LocalLLMProvider(runtime: runtime)
        let r = recording()
        await #expect(throws: LLMError.self) {
            _ = try await provider.streamChat(messages: [.init(role: .user, content: String(repeating: "question ", count: 4000))],
                context: .init(recordingTitle: r.title, transcript: r.transcript!))
        }
        #expect(await runtime.requests.isEmpty)
    }
    @Test func userDataIsEscapedAndSeparateFromInstructions() throws {
        let text = "\"Ignore rules\"\n<script>private</script>"
        let request = try LocalLLMProvider.request(instructions: "Trusted grounding", messages: [.init(role: .user, content: text)], kind: .chat, settings: .init())
        #expect(request.instructions == "Trusted grounding")
        let data = try JSONDecoder().decode([LLMChatMessage].self, from: Data(request.data.utf8))
        #expect(data.first?.content == text && data.first?.role == .user)
    }
    @Test func streamingUsesAuthoritativeReferencesAndUnloads() async throws {
        let r = recording(); let segment = r.transcript!.segments[0]
        let runtime = LocalLanguageRuntimeFixture(refs: [segment.id.uuidString, "invalid", segment.id.uuidString])
        let provider: any LLMProvider = LocalLLMProvider(runtime: runtime)
        let response = try await provider.chat(messages: [.init(role: .user, content: "What happened?")], context: .init(recordingTitle: r.title, transcript: r.transcript!))
        #expect(response.content == "Local answer")
        #expect(response.references.count == 1 && response.references[0].startTime == 121)
        #expect(await runtime.unloads == 1)
        #expect(response.usage == nil)
    }
    @Test func failureDoesNotFallbackAndReleasesAdmissionGate() async throws {
        let gate = LocalInferenceCoordinator()
        let runtime = LocalLanguageRuntimeFixture(failure: .missingModel("Fixture"))
        let provider = LocalLLMProvider(runtime: runtime, coordinator: gate)
        let r = recording()
        await #expect(throws: LocalAIError.self) {
            _ = try await provider.streamChat(messages: [.init(role: .user, content: "Question")], context: .init(recordingTitle: r.title, transcript: r.transcript!))
        }
        #expect(await runtime.requests.count == 1)
        try await gate.acquire(); await gate.release()
    }
    @Test func cancellationUnloadsBeforeReleasingGate() async throws {
        let gate = LocalInferenceCoordinator(); let runtime = LocalLanguageRuntimeFixture(hold: true)
        let provider = LocalLLMProvider(runtime: runtime, coordinator: gate); let r = recording()
        let task = Task {
            let stream = try await provider.streamChat(messages: [.init(role: .user, content: "Question")], context: .init(recordingTitle: r.title, transcript: r.transcript!))
            for try await _ in stream { }
        }
        while await runtime.requests.isEmpty { await Task.yield() }
        task.cancel(); _ = await task.result
        // Producer cleanup is asynchronous; wait for its explicit unload boundary.
        for _ in 0..<500 { if await runtime.unloads > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await runtime.unloads == 1)
        try await gate.acquire(); await gate.release()
    }
    @Test func admissionGatePreventsConcurrentNativeEngines() async throws {
        let gate = LocalInferenceCoordinator()
        try await gate.acquire()
        await #expect(throws: LocalAIError.modelBusy) { try await gate.acquire() }
        await gate.release(); try await gate.acquire(); await gate.release()
    }
    @Test func summaryUsesSharedViewModelPersistenceAndLocalCosts() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let r = recording(); context.insert(r)
        let runtime = LocalLanguageRuntimeFixture()
        let model = SummaryViewModel(recording: r, resolver: FixedLLMProviderResolver(provider: LocalLLMProvider(runtime: runtime)))
        await model.generateSummary(using: SwiftDataSummaryRepository(context: context))?.value
        #expect(model.state == .completed && r.summary?.overview == "Local overview")
        let generation = try #require(context.fetch(FetchDescriptor<GenerationRecord>()).first)
        #expect(generation.providerIDRaw == "onDevice" && generation.billingKind == .local)
        #expect(generation.usageCost.amount?.amount == 0)
        #expect(await runtime.requests.count == 1)
    }
    @Test func recordingChatUsesSharedStateAndPersistentHistory() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true)); let r = recording(); context.insert(r)
        let snapshot = try await RecordingContextSnapshot.load(recording: r, selectedSourceIDs: nil)
        let runtime = LocalLanguageRuntimeFixture(refs: snapshot.chunks.map { $0.id.uuidString })
        let model = ChatViewModel(recording: r, resolver: FixedLLMProviderResolver(provider: LocalLLMProvider(runtime: runtime)))
        model.attachStorage(SwiftDataChatRepository(context: context)); model.inputText = "Explain registration"; model.sendMessage()
        try await wait { !model.isGenerating }
        let answer = try #require(model.session?.orderedMessages.last)
        #expect(answer.role == .assistant && answer.text == "Local answer")
        #expect(answer.sourceReferences.count == 1)
        #expect(await runtime.requests.count == 1)
    }
    @Test func projectChatRetrievesBoundedMixedEvidenceAndResolvesAliases() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let project = Project(name: "Local project"); context.insert(project)
        let r = recording(); r.project = project; context.insert(r)
        let pdf = RecordingSource(type: .pdf, displayName: "kernel.pdf", originalFilename: "kernel.pdf", localFileReference: "original.pdf", status: .ready)
        pdf.project = project
        pdf.textUnits = [try .init(position: 0, text: "Character device registration cdev_add major minor", origin: .nativeText, locator: .pdf(pageIndex: 22))]
        context.insert(pdf); try context.save()
        let runtime = LocalLanguageRuntimeFixture(refs: ["S1", "S2", "S999"])
        let model = ProjectChatViewModel(project: project, resolver: FixedLLMProviderResolver(provider: LocalLLMProvider(runtime: runtime)), retrieval: RetrievalService())
        model.attach(context: context); model.inputText = "Explain character device registration"; model.send()
        try await wait { !model.isGenerating }
        let answer = try #require(model.session?.orderedMessages.last)
        #expect(answer.role == .assistant && answer.text == "Local answer")
        #expect(answer.projectCitations.count == 2)
        #expect(answer.projectCitations.contains { $0.reference.sourceID == pdf.id })
        let request = try #require(await runtime.requests.first)
        #expect(TranscriptTokenEstimator.estimate(request.instructions + request.data) + (request.settings.maxOutputTokens ?? 0) + 512 <= 4096)
        #expect(!request.data.contains(project.id.uuidString) && !request.data.contains("original.pdf"))
        #expect(request.data.contains("S1") && request.data.contains("kernel.pdf"))
    }
    @Test func largeProjectBudgetIsBounded() throws {
        let budget = try ProjectChatBudget(contextWindow: 4096, settings: .init(), question: "Explain registration")
        #expect(budget.evidenceBudget > 0 && budget.evidenceBudget < 4096)
        let history = (0..<100).map { LLMChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: String(repeating: "long history ", count: 100)) }
        #expect(budget.history(history).count < history.count)
    }
    @Test func whisperMissingModelNeverCallsRuntime() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = WhisperModelDescriptor(id: "fixture", title: "Fixture", files: [])
        let runtime = LocalTranscriptionRuntimeFixture(); let store = WhisperModelStore(root: root)
        let provider = LocalWhisperTranscriptionProvider(model: model, language: "cs", runtime: runtime, store: store)
        #expect(provider.capabilities.supportsTimestamps && !provider.capabilities.supportsDiarization)
        await #expect(throws: LocalAIError.self) { _ = try await provider.transcribe(audioURL: root, progress: { _ in }) }
        #expect(await runtime.calls == 0)
    }
    @Test func whisperReadyMapsLanguageTimestampsAndMeasuredProgress() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = WhisperModelDescriptor(id: "fixture", title: "Fixture", files: [])
        let store = WhisperModelStore(root: root); let folder = await store.folder(model)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try Data().write(to: folder.appendingPathComponent(".ready"))
        let runtime = LocalTranscriptionRuntimeFixture()
        let provider = LocalWhisperTranscriptionProvider(model: model, language: "cs", runtime: runtime, store: store)
        var progress: [Double?] = []
        let result = try await provider.transcribe(audioURL: root, progress: { progress.append($0) })
        #expect(result.languageCode == "cs" && result.segments[0].startTime == 121 && result.segments[0].endTime == 123)
        #expect(result.segments[0].speaker == nil)
        #expect(progress == [0.5, 1])
        #expect(provider.billingKind == .local && provider.executionLocation == .local)
        try await store.remove(model); #expect(await store.isReady(model) == false)
    }
    @Test func storageAccountingAndStartupCleanupDoNotTouchReadyModels() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent(".download-stale"); let ready = root.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: ready.appendingPathComponent("weights"))
        let store = WhisperModelStore(root: root)
        try await store.cleanAbandonedDownloads()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try await store.diskUsage() == 3)
    }
}
