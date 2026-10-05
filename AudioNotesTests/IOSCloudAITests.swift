#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import AudioNotes

private actor TestCredentialStore: CredentialStoring {
    private var keys: [CredentialAccount: String] = [:]
    var failure: KeychainError?

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

@MainActor
struct IOSCloudAITests {
    @Test func iOSProviderCapabilitiesReflectSupportedCloudProviders() {
        let llmSelectable = LLMProviderID.currentPlatformSelectable
        #expect(llmSelectable.contains(.openAI))
        #expect(!llmSelectable.contains(.anthropic))
        #expect(!llmSelectable.contains(.ollama))
        #expect(!llmSelectable.contains(.llamaCpp))
        #expect(llmSelectable.contains(.gemini))

        let transcriptionSelectable = TranscriptionProviderID.currentPlatformSelectable
        #expect(transcriptionSelectable.contains(.openAI))
        #expect(!transcriptionSelectable.contains(.localWhisper))
    }

    @Test func iOSGoogleOAuthUsesRegisteredNativeClientAndCallbackScheme() throws {
        let config = try GoogleOAuthConfiguration.load(bundle: .main)
        #expect(config.redirectScheme == "com.googleusercontent.apps.576974561449-mrqi6hj029poen9emjp0658p09gkd4kt")
        #expect(config.clientID.hasSuffix(".apps.googleusercontent.com"))
        #expect(!config.projectID.isEmpty)
        #expect(config.clientSecret == nil)
    }

    @Test func googleNativeCallbackParsesCodeStateAndDenial() throws {
        let success = try #require(URL(string: "com.googleusercontent.apps.576974561449-mrqi6hj029poen9emjp0658p09gkd4kt:/oauth2redirect?code=sample-code&state=random-state&scope=openid"))
        let parsed = GoogleGeminiOAuthService.callbackResult(from: success)
        #expect(parsed.code == "sample-code")
        #expect(parsed.state == "random-state")
        #expect(GoogleGeminiOAuthService.callbackMatchesState(parsed.state, expected: "random-state"))

        let denied = try #require(URL(string: "com.googleusercontent.apps.576974561449-mrqi6hj029poen9emjp0658p09gkd4kt:/oauth2redirect?error=access_denied&state=random-state"))
        #expect(GoogleGeminiOAuthService.callbackResult(from: denied).error == "access_denied")
    }

    @Test func iOSSettingsManagesOpenAIKeychainCredential() async throws {
        let store = TestCredentialStore()
        let transcriptionConfig = TranscriptionConfiguration()
        let llmConfig = LLMConfiguration()
        let model = ProviderSettingsViewModel(
            credentials: store,
            transcriptionConfig: transcriptionConfig,
            llmConfig: llmConfig
        )

        await model.refresh()
        #expect(!model.keyIsConfigured)

        model.keyInput = "sk-test-ios-key-12345"
        await model.saveKey()
        #expect(model.keyIsConfigured)
        #expect(model.keyInput.isEmpty)
        #expect(try await store.apiKey(for: .openAI) == "sk-test-ios-key-12345")

        await model.removeKey()
        #expect(!model.keyIsConfigured)
        #expect(try await store.apiKey(for: .openAI) == nil)
    }

    @Test func iOSTranscriptionProducesPersistedTranscriptAndGenerationRecord() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let audio = try await AudioImportService(storage: workspace.storage).importFile(at: workspace.makeAudio())
        let recording = Recording(id: audio.id, title: audio.title, audioFileName: audio.fileName, originalFileName: audio.originalFileName, duration: audio.duration)
        context.insert(recording)
        try context.save()

        let resolver = FixedTranscriptionProviderResolver(provider: MockTranscriptionProvider())
        let viewModel = RecordingViewModel(recording: recording, resolver: resolver, storage: workspace.storage)

        let transcriptRepo = SwiftDataTranscriptRepository(context: context)
        viewModel.startTranscription(using: transcriptRepo)

        // Wait for state to reach completed
        while viewModel.state.isProcessing {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(viewModel.state == TranscriptionState.completed)
        #expect(recording.transcript != nil)
        #expect(recording.transcript?.segments.isEmpty == false)

        // Verify generation record exists
        let records = try context.fetch(FetchDescriptor<GenerationRecord>())
        #expect(!records.isEmpty)
        #expect(records.contains(where: { $0.recordingID == recording.id && $0.featureRaw == "transcription" }))
    }

    @Test func iOSSummaryProducesStructuredSummaryAndGenerationRecord() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let recording = Recording(title: "iOS Summary Audio", audioFileName: "test.m4a", originalFileName: "test.m4a", duration: 30.0)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0.0, endTime: 5.0, text: "Discussed quarterly roadmap."),
            TranscriptSegment(position: 1, startTime: 5.0, endTime: 12.0, text: "Action item: Deploy iOS cloud AI.")
        ]
        recording.transcript = transcript
        context.insert(recording)
        try context.save()

        let resolver = FixedLLMProviderResolver(provider: MockLLMProvider())
        let summaryModel = SummaryViewModel(recording: recording, resolver: resolver)

        let summaryRepo = SwiftDataSummaryRepository(context: context)
        summaryModel.generateSummary(using: summaryRepo)

        while summaryModel.state.isGenerating {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(summaryModel.state == SummaryState.completed)
        #expect(recording.summary != nil)

        let records = try context.fetch(FetchDescriptor<GenerationRecord>())
        #expect(records.contains(where: { $0.recordingID == recording.id && $0.featureRaw == "summary" }))
    }

    @Test func iOSChatAllowsMessagingAndClearingHistory() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let recording = Recording(title: "iOS Chat Audio", audioFileName: "test.m4a", originalFileName: "test.m4a", duration: 20.0)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0.0, endTime: 10.0, text: "The primary project goal is native iOS parity.")
        ]
        recording.transcript = transcript
        context.insert(recording)
        try context.save()

        let resolver = FixedLLMProviderResolver(provider: MockLLMProvider())
        let chatModel = ChatViewModel(recording: recording, resolver: resolver)
        let chatRepo = SwiftDataChatRepository(context: context)
        chatModel.attachStorage(chatRepo)

        #expect(chatModel.hasReadySources)
        #expect(chatModel.session != nil)

        chatModel.inputText = "What is the primary goal?"
        chatModel.sendMessage()

        while chatModel.isGenerating {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(chatModel.generationState == ChatGenerationState.completed)
        #expect((chatModel.session?.messages.count ?? 0) >= 2)

        // Clear chat
        chatModel.clearChat()
        #expect(chatModel.session?.messages.isEmpty == true)

        // Transcript is unaffected
        #expect(recording.transcript != nil)
    }

    @Test func iOSCitationResolutionFindsCorrectTimestamp() async throws {
        let segment1 = TranscriptSegment(position: 0, startTime: 12.5, endTime: 18.0, text: "Key point at 12 seconds")
        let segment2 = TranscriptSegment(position: 1, startTime: 25.0, endTime: 32.0, text: "Second point at 25 seconds")
        let segments = [
            TranscriptSegmentSnapshot(segment: segment1),
            TranscriptSegmentSnapshot(segment: segment2)
        ]

        let resolver = TranscriptReferenceResolver()
        let references = resolver.resolve(segmentIDs: [segment1.id.uuidString], against: segments)

        #expect(references.count == 1)
        #expect(references.first?.startTime == 12.5)
    }
}
#endif
