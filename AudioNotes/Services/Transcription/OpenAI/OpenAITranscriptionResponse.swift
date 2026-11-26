import Foundation

/// Provider DTOs stay in the service layer; only mapped domain models reach the UI.
struct OpenAITranscriptionResponse: Codable, Sendable {
    let text: String
    let language: String?
    let duration: Double?
    let segments: [Segment]?

    struct Segment: Codable, Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    @MainActor
    func makeTranscript(modelName: String = "whisper-1", audioDuration: Double = 0) throws -> Transcript {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let validSegments: [(start: Double, end: Double, text: String)]?
        if let segments {
            guard segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite }) else {
                throw OpenAITranscriptionError.invalidResponse
            }
            validSegments = segments.compactMap { segment in
                let segmentText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segmentText.isEmpty else { return nil }
                let start = max(0, segment.start)
                let end = max(start, segment.end)
                return (start, end, segmentText)
            }
        } else {
            validSegments = nil
        }

        guard !trimmed.isEmpty || (validSegments?.isEmpty == false) else {
            throw OpenAITranscriptionError.noSpeech
        }

        let resolvedDuration: Double? = if let duration, duration.isFinite, duration > 0 {
            duration
        } else if audioDuration.isFinite, audioDuration > 0 {
            audioDuration
        } else {
            nil
        }

        if let validSegments {
            guard let effectiveDuration = resolvedDuration else {
                throw OpenAITranscriptionError.invalidResponse
            }
            let transcript = Transcript(languageCode: languageCode, sourceName: "OpenAI · \(modelName)")
            if validSegments.isEmpty {
                transcript.segments = [
                    TranscriptSegment(
                        position: 0,
                        startTime: 0,
                        endTime: effectiveDuration,
                        text: trimmed,
                        speaker: nil
                    )
                ]
            } else {
                transcript.segments = validSegments.enumerated().map { index, segment in
                    TranscriptSegment(
                        position: index,
                        startTime: segment.start,
                        endTime: segment.end,
                        text: segment.text,
                        speaker: nil
                    )
                }
            }
            return transcript
        } else {
            // Simple json format with text only
            let effectiveDuration = resolvedDuration ?? 1.0
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
