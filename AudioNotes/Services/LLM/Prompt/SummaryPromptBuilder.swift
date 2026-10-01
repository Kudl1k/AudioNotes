import Foundation

struct FormattedTranscriptContext: Sendable {
    let text: String
    let segmentCount: Int
    let approximateTokens: Int
}

struct SummaryPrompt: Sendable {
    let systemMessage: String
    let userMessage: String
    var images: [LLMImageInput] = []
}

struct SummaryPromptBuilder: Sendable {
    static let maxSupportedTokens = 100_000
    static let titleInstruction = "Generate a fresh, concise, descriptive title in the title field (about 3–10 words) that reflects the main subject of this summary. Use the same language as the summary and plain text, without Markdown, quotation marks, or a generic label such as Summary. Ground the title in the provided content."

    init() {}

    func formatTranscript(_ transcript: Transcript) throws -> FormattedTranscriptContext {
        let segments = transcript.segments.sorted { $0.startTime < $1.startTime }
        guard !segments.isEmpty else {
            throw LLMError.transcriptEmpty
        }

        var lines: [String] = []
        lines.reserveCapacity(segments.count * 3)

        for segment in segments {
            let start = AudioTime.format(segment.startTime)
            let end = AudioTime.format(segment.endTime)
            let header: String
            if let speaker = segment.speaker, !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                header = "[\(start) - \(end)] \(speaker):"
            } else {
                header = "[\(start) - \(end)]"
            }
            lines.append(header)
            lines.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }

        let formatted = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formatted.isEmpty else {
            throw LLMError.transcriptEmpty
        }

        let approximateTokens = max(1, formatted.count / 4)
        if approximateTokens > Self.maxSupportedTokens {
            throw LLMError.contextTooLarge(approximateTokens: approximateTokens)
        }

        return FormattedTranscriptContext(
            text: formatted,
            segmentCount: segments.count,
            approximateTokens: approximateTokens
        )
    }

    func buildPrompt(
        transcriptContext: FormattedTranscriptContext,
        configuration: SummaryConfiguration
    ) -> SummaryPrompt {
        var systemLines = [
            "You are an expert executive assistant and summarizer for AudioNotes.",
            "Your task is to analyze the provided timestamped audio transcript and generate a structured summary.",
            Self.titleInstruction,
            "",
            "CRITICAL GROUNDING RULES:",
            "1. Grounding: Summarize ONLY facts, statements, questions, and decisions explicitly supported by the transcript.",
            "2. No hallucinations: Never invent decisions, action items, names, dates, or timestamps.",
            "3. Decisions vs. Discussion: Distinguish explicit decisions from general discussion or open ideas.",
            "4. Optional fields: If an assignee, due date, speaker, or timestamp cannot be determined with certainty, set it to null.",
            "5. Timestamps: When referencing decisions, action items, open questions, or important quotes, provide the starting timestamp in seconds (timestampSeconds) corresponding to the transcript segment where it was spoken. Never fabricate a timestamp.",
            "6. Empty sections: If the transcript does not contain content for a section (for example, no decisions were made, or no action items exist), return an empty array for that section.",
            "",
            "PRESET FOCUS (\(configuration.preset.title.uppercased())):",
            configuration.preset.systemInstructions
        ]
        systemLines.append("")
        systemLines.append("RESPONSE LENGTH: \(OutputLengthInstructionBuilder.instruction(for: configuration.outputLength))")

        let userLines = [
            "Below is the complete transcript with timestamps [start - end]:",
            "",
            transcriptContext.text
        ]

        if configuration.preset == .custom,
           let instructions = configuration.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            systemLines.append("")
            systemLines.append("ADDITIONAL USER INSTRUCTIONS:")
            systemLines.append(instructions)
        }

        return SummaryPrompt(
            systemMessage: systemLines.joined(separator: "\n"),
            userMessage: userLines.joined(separator: "\n")
        )
    }
}
