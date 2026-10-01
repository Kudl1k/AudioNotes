import Foundation
import AVFoundation
import Testing
@testable import AudioNotes

/// Explicit opt-in only: TEST_RUNNER_AUDIONOTES_LIVE_WHISPER=1 xcodebuild test ...
/// Downloads Tiny (~80 MB), runs Core ML, then deletes its temporary model copy.
@MainActor struct LocalAILiveTests {
    /// Metadata only: no recording content, tokenization, or inference.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUDIONOTES_LIVE_LLAMACPP"] == "1"))
    func nativeAppCanReadLlamaCppContext() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["AUDIONOTES_LIVE_LLAMACPP_ADDRESS"])
        let name = try #require(ProcessInfo.processInfo.environment["AUDIONOTES_LIVE_LLAMACPP_MODEL"])
        let defaults = try #require(UserDefaults(suiteName: "llama-live-" + UUID().uuidString))
        let config = LocalAIConfiguration(defaults: defaults)
        config.llamaCppAddress = address
        let provider = LlamaCppLLMProvider(model: name, configuration: config)
        try await provider.prepareForGeneration()
        #expect(provider.inputCapabilities.contextWindowTokens > 0)
    }

    /// Exercises connection reuse with synthetic source data only; never runs inference.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUDIONOTES_LIVE_LLAMACPP"] == "1"))
    func nativeAppCanRepeatedlySizeLlamaCppPrompts() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["AUDIONOTES_LIVE_LLAMACPP_ADDRESS"])
        let name = try #require(ProcessInfo.processInfo.environment["AUDIONOTES_LIVE_LLAMACPP_MODEL"])
        let config = LocalAIConfiguration(defaults: try #require(UserDefaults(suiteName: "llama-sizing-live-" + UUID().uuidString)))
        config.llamaCppAddress = address
        let provider = LlamaCppLLMProvider(model: name, configuration: config)
        for index in 0..<150 {
            try Task.checkCancellation()
            let chunk = SourceChunk(id: UUID(), sourceID: UUID(), sourceName: "Synthetic connection fixture",
                sourceType: .document, text: "Connection fixture \(index). " + String(repeating: "Synthetic text. ", count: 40),
                locator: .document(section: "Fixture", start: 0, end: 600), origin: .nativeText)
            #expect(try await provider.summaryRequestFits(context: .init(chunks: [chunk]), configuration: .init()))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUDIONOTES_LIVE_OLLAMA"] == "1"))
    func nativeSandboxCanContactLocalOllama() async throws {
        let address = ProcessInfo.processInfo.environment["AUDIONOTES_LIVE_OLLAMA_ADDRESS"] ?? "http://localhost:11434"
        let models = try await OllamaClient().models(endpoint: OllamaEndpoint(address))
        // This machine may have stale index entries; discovery must still return safely.
        #expect(models.allSatisfy { !$0.id.hasSuffix(":cloud") })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUDIONOTES_LIVE_WHISPER"] == "1"))
    func tinyWhisperDownloadsAndTranscribesEnglishNatively() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("whisper-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try #require(WhisperModelDescriptor.bundled.first { $0.title == "Tiny" })
        let store = WhisperModelStore(root: root)
        try await store.install(model) { _ in }
        #expect(await store.isReady(model))
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/samples/jfk.wav")!)
        let audio = root.appendingPathComponent("speech.wav")
        try data.write(to: audio)
        let provider = LocalWhisperTranscriptionProvider(model: model, language: "en", store: store)
        let transcript = try await provider.transcribe(audioURL: audio, progress: { _ in })
        #expect(transcript.orderedSegments.map(\.text).joined(separator: " ").lowercased().contains("country"))
        #expect(transcript.segmentSnapshots.allSatisfy { $0.startTime >= 0 && $0.endTime >= $0.startTime })
        #expect(transcript.languageCode == "en")
        if let path = ProcessInfo.processInfo.environment["AUDIONOTES_LIVE_CZECH_PATH"] {
            let czech = root.appendingPathComponent("czech.aiff")
            try Data(contentsOf: URL(filePath: path)).write(to: czech)
            let czechProvider = LocalWhisperTranscriptionProvider(model: model, language: "cs", store: store)
            let result = try await czechProvider.transcribe(audioURL: czech, progress: { _ in })
            #expect(result.languageCode == "cs")
            #expect(result.orderedSegments.map(\.text).joined(separator: " ").folding(options: [.diacriticInsensitive], locale: Locale(identifier: "cs_CZ")).lowercased().contains("pamet"))
        }
        // Exercise two independent PCM windows and verify original-audio offsets.
        let input = try AVAudioFile(forReading: audio)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)))
        try input.read(into: buffer)
        let longAudio = root.appendingPathComponent("long.wav")
        do {
            let writer = try AVAudioFile(forWriting: longAudio, settings: input.fileFormat.settings,
                commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
            for _ in 0..<13 { try writer.write(from: buffer) }
        }
        let longResult = try await provider.transcribe(audioURL: longAudio, progress: { _ in })
        #expect(longResult.segmentSnapshots.contains { $0.startTime >= 120 })
        let cancelled = Task { _ = try await provider.transcribe(audioURL: longAudio, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(300))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await store.remove(model)
        #expect(await store.isReady(model) == false)
    }
}
