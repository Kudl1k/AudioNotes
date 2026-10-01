import Foundation
import AVFoundation
import WhisperKit
import ArgmaxCore

/// Worker isolation keeps PCM conversion and inference away from UI state.
actor WhisperKitRuntime: LocalWhisperRunning {
    func transcribe(audioURL: URL, modelFolder: URL, language: String?,
                    status: @escaping LocalWhisperStatusReporter) async throws -> LocalWhisperResult {
        #if !arch(arm64)
        throw LocalAIError.unsupportedHardware
        #else
        try Task.checkCancellation()
        let audio = try AVAudioFile(forReading: audioURL)
        let total = Double(audio.length) / audio.processingFormat.sampleRate
        guard total.isFinite, total > 0 else { throw TranscriptionError.invalidAudio }
        let engine = try await OfflineWhisperKit(WhisperKitConfig(modelFolder: modelFolder.path,
            tokenizerFolder: modelFolder, verbose: false, prewarm: false, load: true, download: false))
        var output: [LocalWhisperSegment] = []
        var detected = language
        do {
            var offset: TimeInterval = 0
            // Bounded PCM inference windows are independent of cloud upload limits and retrieval chunks.
            while offset < total {
                try Task.checkCancellation()
                let end = min(total, offset + 120)
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path, startTime: offset, endTime: end)
                let options = DecodingOptions(language: detected, detectLanguage: detected == nil,
                    skipSpecialTokens: true, wordTimestamps: false, concurrentWorkerCount: 1)
                let results = try await engine.transcribe(audioArray: samples, decodeOptions: options, callback: { _ in
                    Task.isCancelled ? false : nil
                })
                try Task.checkCancellation()
                if detected == nil { detected = results.first?.language }
                for result in results {
                    output.append(contentsOf: result.segments.map {
                        LocalWhisperSegment(start: offset + Double($0.start), end: min(total, offset + Double($0.end)), text: $0.text)
                    })
                }
                offset = end
                await status(offset, total)
            }
            await engine.unloadModels()
            return LocalWhisperResult(language: detected, segments: output)
        } catch {
            await engine.unloadModels()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        #endif
    }
}

/// Upstream's default tokenizer loader falls back to the Hub even with download:false.
/// Override that entry point with local-only parsing; malformed/missing files fail closed.
private final class OfflineWhisperKit: WhisperKit {
    override func loadTokenizerIfNeeded() async throws {
        guard tokenizer == nil else { return }
        guard let folder = modelFolder, let logits = textDecoder.logitsSize else { throw LocalAIError.invalidResponse }
        textDecoder.isModelMultilingual = logits >= 51865
        let local = try await AutoTokenizerWrapper.from(modelFolder: folder)
        tokenizer = try OfflineWhisperTokenizer(tokenizer: local)
    }
}

private struct OfflineWhisperTokenizer: WhisperTokenizer {
    let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>
    init(tokenizer: TokenizerWrapper) throws {
        self.tokenizer = tokenizer
        func token(_ name: String) throws -> Int {
            guard let value = tokenizer.convertTokenToId(name) else { throw LocalAIError.invalidResponse }
            return value
        }
        specialTokens = try SpecialTokens(endToken: token("<|endoftext|>"), englishToken: token("<|en|>"),
            noSpeechToken: token("<|nospeech|>"), noTimestampsToken: token("<|notimestamps|>"), specialTokenBegin: token("<|endoftext|>"),
            startOfPreviousToken: token("<|startofprev|>"), startOfTranscriptToken: token("<|startoftranscript|>"),
            timeTokenBegin: token("<|0.00|>"), transcribeToken: token("<|transcribe|>"), translateToken: token("<|translate|>"),
            whitespaceToken: tokenizer.convertTokenToId(" ") ?? 220)
        allLanguageTokens = Set(Constants.languages.values.compactMap { tokenizer.convertTokenToId("<|\($0)|>") })
    }
    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }
    // Segment timestamps are the M10 contract; word timestamps are disabled.
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        (tokenIds.map { decode(tokens: [$0]) }, tokenIds.map { [$0] })
    }
}

/// Runtime-derived metadata exposed without importing the SDK into feature code.
enum LocalWhisperRuntimeCapabilities {
    static var languageCodes: Set<String> { Constants.languageCodes }
    static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}
