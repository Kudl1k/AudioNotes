import Foundation

/// Provider DTOs stay in the service layer; only mapped domain models reach the UI.
struct OpenAITranscriptionResponse: Decodable, Sendable {
    let text: String
    let language: String?
    let duration: Double?
    let segments: [Segment]?

    struct Segment: Decodable, Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    @MainActor
    func makeTranscript(modelName: String = "whisper-1", audioDuration: Double = 0) throws -> Transcript {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAITranscriptionError.noSpeech }

        if let segments {
            // When segments is present, it must be valid and non-empty (as returned by verbose_json)
            guard let duration, duration.isFinite, duration > 0 else { throw OpenAITranscriptionError.invalidResponse }
            guard !segments.isEmpty, segments.allSatisfy({
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start &&
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else { throw OpenAITranscriptionError.invalidResponse }

            let transcript = Transcript(languageCode: languageCode, sourceName: "OpenAI · \(modelName)")
            transcript.segments = segments.enumerated().map { index, segment in
                TranscriptSegment(
                    position: index,
                    startTime: segment.start,
                    endTime: segment.end,
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    speaker: nil
                )
            }
            return transcript
        } else {
            // Simple json format with text only
            let effectiveDuration = duration ?? (audioDuration > 0 ? audioDuration : 1.0)
            let transcript = Transcript(languageCode: languageCode, sourceName: "OpenAI · \(modelName)")
            transcript.segments = [
                TranscriptSegment(
                    position: 0,
                    startTime: 0,
                    endTime: effectiveDuration,
                    text: trimmed,
                    speaker: nil
                )
            ]
            return transcript
        }
    }

    private var languageCode: String? {
        guard let language else { return nil }
        let value = language.lowercased()
        // whisper-1 verbose_json returns names such as "english", not always ISO codes.
        let locale = Locale(identifier: "en")
        return Locale.LanguageCode.isoLanguageCodes.first {
            $0.identifier == value || locale.localizedString(forLanguageCode: $0.identifier)?.lowercased() == value
        }?.identifier
    }
}
