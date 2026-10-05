import Foundation
import Testing
@testable import AudioNotes

@Suite
@MainActor
struct GeminiTranscriptionTests {
    @Test func requestUsesOfficialAudioFileAndTimestampDiarizationContract() throws {
        let data = try JSONSerialization.data(withJSONObject: GeminiTranscriptionRequestBuilder.body(
            model: "gemini-3.5-transcribe", uri: "https://generativelanguage.googleapis.com/file/example", mimeType: "audio/mp4"))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "gemini-3.5-transcribe")
        #expect(body["store"] as? Bool == false)
        let input = try #require((body["input"] as? [[String: Any]])?.first)
        #expect(input["type"] as? String == "audio")
        #expect(input["mime_type"] as? String == "audio/mp4")
        let config = try #require(body["generation_config"] as? [String: Any])
        let transcription = try #require(config["transcription_config"] as? [String: Any])
        let mode = try #require(transcription["mode"] as? [String: Any])
        #expect(mode["type"] as? String == "verbatim")
        #expect(mode["diarization_mode"] as? String == "speaker")
        #expect(mode["timestamp_granularities"] as? [String] == ["word"])
    }

    @Test func mapsTimestampedDiarizedWordsToNativeSegments() throws {
        let response = #"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"Hi there.","annotations":[{"type":"word_info","text":"Hi","speaker":"spk_1","start_offset":"0.100s","end_offset":"0.350s"},{"type":"word_info","text":"there.","speaker":"spk_2","start_offset":"0.400s","end_offset":"0.850s"}]}]}]}"#
        let transcript = try GeminiTranscriptMapper.makeTranscript(from: Data(response.utf8), duration: 2)
        #expect(transcript.orderedSegments.map(\.text) == ["Hi", "there."])
        #expect(transcript.orderedSegments.map(\.startTime) == [0.1, 0.4])
        #expect(transcript.orderedSegments.map(\.endTime) == [0.35, 0.85])
        #expect(transcript.orderedSegments.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    @Test func fallsBackToNativeFullDurationSegmentWhenNoAnnotations() throws {
        let response = #"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"A short transcript."}]}]}"#
        let transcript = try GeminiTranscriptMapper.makeTranscript(from: Data(response.utf8), duration: 12)
        #expect(transcript.orderedSegments.count == 1)
        #expect(transcript.orderedSegments[0].startTime == 0)
        #expect(transcript.orderedSegments[0].endTime == 12)
        #expect(transcript.orderedSegments[0].text == "A short transcript.")
        #expect(transcript.orderedSegments[0].speaker == nil)
    }

    @Test func exposesProviderSpecificFileAndTimestampCapabilities() {
        let provider = GeminiTranscriptionProvider(model: "gemini-3.5-transcribe", oauth: GoogleGeminiOAuthService())
        #expect(provider.capabilities.maxDirectUploadSize == nil)
        #expect(provider.capabilities.maxProviderFileUploadSize == 2_000_000_000)
        #expect(provider.capabilities.supportsProviderFileUpload)
        #expect(provider.capabilities.supportsTimestamps)
        #expect(provider.capabilities.supportsDiarization)
        #expect(provider.capabilities.maximumDuration == 1_800)
        #expect(!provider.capabilities.requiresChunking)
        #expect(GeminiTranscriptionProvider.mimeType(for: URL(fileURLWithPath: "/tmp/recording.m4a")) == "audio/mp4")
        #expect(GeminiTranscriptionProvider.mimeType(for: URL(fileURLWithPath: "/tmp/recording.xyz")) == nil)
        #expect(GeminiTranscriptionProvider.mimeType(for: URL(fileURLWithPath: "/tmp/recording.caf")) == nil)
        let cost = CostCalculator().calculate(
            transcription: TranscriptionUsage(recordingDuration: 60, processedDuration: 60),
            pricing: nil, billing: .meteredAPI
        )
        #expect(cost.amount == nil)
        #expect(cost.status == .unknownPricing)
    }
}
